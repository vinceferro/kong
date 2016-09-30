local singletons = require "kong.singletons"
local cache = require "kong.tools.database_cache"
local dns_client = require "dns.client"  -- due to startup/require order, cannot use the one from 'singletons' here
local ring_balancer = require "dns.balancer"
local toip = dns_client.toip

--===========================================================
-- Ring-balancer based resolution
--===========================================================
local balancers = {}  -- table holding our balancer objects, indexed by upstream name

-- TODO: review caching strategy, multiple large slots lists might take a lot of time deserializing
-- upon every request. Same for targets list. Check how to do it more efficient.

local function load_upstreams_into_memory()
  local upstreams, err = singletons.dao.upstreams:find_all()
  if err then
    return nil, err
  end
  
  -- build a dictionary, indexed by the upstreams name
  local upstream_dic = {}
  for _, up in ipairs(upstreams) do
    upstream_dic[up.name] = up
  end
  
  return upstream_dic
end

-- @param upstream_id Upstream uuid for which to load the target history
local function load_targets_into_memory(upstream_id)
  local target_history, err = singletons.dao.targets:find_all {upstream_id = upstream_id}
  if err then
    return nil, err
  end
  
  -- split `target` field into `name` and `port`
  for _, target in ipairs(target_history) do
    local port
    target.name, port = string.match(target.target, "^(.-):(%d+)$")
    target.port = tonumber(port)
  end
  
  -- order by 'created_at'
  table.sort(target_history, function(a,b) return a.created_at<b.created_at end)

  return target_history
end

-- applies the history of lb transactions from index `start` forward
-- @param rb ring-balancer object
-- @param history list of targets/transactions to be applied
-- @param start the index where to start in the `history` parameter
-- @return true
local function apply_history(rb, history, start)
  
  for i = start, #history do 
    local target = history[i]
    if target.weight > 0 then
      assert(rb:addHost(target.name, target.port, target.weight))
    else
      assert(rb:removeHost(target.name, target.port))
    end
    rb.targets_history[i] = {
      name = target.name,
      port = target.port,
      weight = target.weight,
      created_at = target.created_at,
    }
  end
  
  return true
end

-- creates a new ring balancer.
local function new_ring_balancer(upstream, history)
  local first = history[1]
  local b, err = ring_balancer.new({
      hosts = { first },   -- just insert the initial host, remainder sequentially later
      wheelsize = upstream.slots,
      dns = dns_client,
      order = upstream.orderlist,
    })
  if not b then return b, err end
  
  -- NOTE: we're inserting a foreign entity in the balancer, to keep track of
  -- target-history changes!
  b.targets_history = {{ 
      name = first.name,
      port = first.port,
      weight = first.weight,
      created_at = first.created_at,
  }}
  
  -- replay history of lb transactions
  apply_history(b, history, 2)
  
  return b
end

-- looks up a balancer for the target.
-- @param target the table with the target details
-- @return balancer if found, or nil if not found, or nil+error on error
local get_balancer = function(target)
  -- NOTE: only called upon first lookup, so `cache_only` limitations do not apply here
  
  -- first go and find the upstream object, from cache or the db
  local upstreams_dic, err = cache.get_or_set(cache.upstreams_key(), load_upstreams_into_memory)
  if err then
    return nil, err
  end
  
  local upstream = upstreams_dic[target.upstream.host]
  if not upstream then
    return nil   -- there is no upstream by this name, so must be regular name, return and try dns 
  end
  
  -- we've got the upstream, now fetch its targets, from cache or the db
  local targets_history, err = cache.get_or_set(cache.targets_key(upstream.id), 
    function() return load_targets_into_memory(upstream.id) end)
  if err or #targets_history == 0 then  -- 'no targets' equals 'no upstream', so exit as well
    return nil, err
  end

  local balancer = balancers[upstream.name]
  if not balancer then
    -- create a new ring balancer
    balancer, err = new_ring_balancer(upstream, targets_history)
    if err then return balancer, err end

    balancers[upstream.name] = balancer

  elseif #balancer.targets_history ~= #targets_history or 
         balancer.targets_history[#balancer.targets_history].created_at ~= targets_history[#targets_history].created_at then
    -- last entries in history don't match, so we must do some updates.
    
    -- compare balancer history with db-loaded history
    local ok = true
    for i = 1, #balancer.targets_history do
      if balancer.targets_history[i].created_at ~= targets_history[i].created_at then
        ok = false
        break
      end
    end
    if ok then
      -- history is the same, so we only need to add new entries
      apply_history(balancer, targets_history, #balancer.targets_history + 1)
    else
      -- history not the same, so a cleanup was done, need to recreate from scratch
      balancer, err = new_ring_balancer(upstream, targets_history)
      if err then return balancer, err end

      balancers[upstream.name] = balancer
    end
  end
  
  return balancer
end


local first_try_balancer = function(target)
  local b = target.balancer
  local hashValue = nil  -- TODO: implement, nil does simple round-robin
  
  local ip, port, hostname = b:getPeer(hashValue, false)
  if not ip then 
    return ip, port
  end
  target.ip = ip
  target.port = port
  target.hostname = hostname
  return true
end

local retry_balancer = function(target)
  local b = target.balancer
  local hashValue = nil  -- TODO: implement, nil does simple round-robin
  
  local ip, port, hostname = b:getPeer(hashValue, true)
  if not ip then 
    return ip, port
  end
  target.ip = ip
  target.port = port
  target.hostname = hostname
  return true
end

--===========================================================
-- simple DNS based resolution
--===========================================================

local first_try_dns = function(target)
  local ip, port = toip(target.upstream.host, target.upstream.port, false)
  if not ip then
    return nil, port
  end
  target.ip = ip
  target.port = port
  return true
end

local retry_dns = function(target)
  local ip, port = toip(target.upstream.host, target.upstream.port, true)
  if type(ip) ~= "string" then
    return nil, port
  end
  target.ip = ip
  target.port = port
  return true
end


--===========================================================
-- Main entry point when resolving
--===========================================================

-- Resolves the target structure in-place (fields `ip` and `port`).
--
-- If the hostname matches an 'upstream' pool, then it must be balanced in that 
-- pool, in this case any port number provided will be ignored, as the pool provides it.
--
-- @param target the data structure as defined in `core.access.before` where it is created
-- @return true on success, nil+error otherwise
local function execute(target)
  if target.type ~= "name" then
    -- it's an ip address (v4 or v6), so nothing we can do...
    target.ip = target.upstream.host
    target.port = target.upstream.port or 80
    return true
  end
  
  -- when tries == 0 it runs before the `balancer` context (in the `access` context),
  -- when tries >= 2 then it performs a retry in the `balancer` context
  if target.tries == 0 then
    local err
    -- first try, so try and find a matching balancer/upstream object
    target.balancer, err = get_balancer(target)
    if err then return nil, err end

    if target.balancer then
      return first_try_balancer(target)
    else
      return first_try_dns(target)
    end
  else
    if target.balancer then
      return retry_balancer(target)
    else
      return retry_dns(target)
    end
  end
end

return { 
  execute = execute,
  load_upstreams_into_memory = load_upstreams_into_memory,  -- exported for test purposes
}