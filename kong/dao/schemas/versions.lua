local url = require "socket.url"

local fmt = string.format
local sub = string.sub
local match = string.match

local function validate_upstream_url_protocol(value)
  local parsed_url = url.parse(value)
  if parsed_url.scheme and parsed_url.host then
    parsed_url.scheme = parsed_url.scheme:lower()
    if not (parsed_url.scheme == "http" or parsed_url.scheme == "https") then
      return false, "Supported protocols are HTTP and HTTPS"
    end
  end

  return true
end

return {
  table = "versions",
  primary_key = {"id"},
  fields = {
    id = {type = "id", dao_insert_value = true, required = true},
    api_id = {type = "id", required = true, foreign = "apis:id"},
    created_at = {type = "timestamp", immutable = true, dao_insert_value = true, required = true},
    version = {type = "string", required = true},
    upstream_url = {type = "url", required = true, func = validate_upstream_url_protocol},
  },
  marshall_event = function(self, t)
    return { id = t.id }
  end
}
