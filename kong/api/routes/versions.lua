local singletons = require "kong.singletons"
local crud = require "kong.api.crud_helpers"
local syslog = require "kong.tools.syslog"
local constants = require "kong.constants"

return {
  ["/versions/"] = {
    GET = function(self, dao_factory)
      crud.paginated_set(self, dao_factory.versions)
    end,

    PUT = function(self, dao_factory)
      crud.put(self.params, dao_factory.versions)
    end,

    POST = function(self, dao_factory)
      crud.post(self.params, dao_factory.versions)
    end
  },

  ["/versions/:id"] = {
    before = function(self, dao_factory, helpers)
      local rows, err = dao_factory.versions:find_all {id = self.params.id}
      if err then
        return helpers.yield_error(err)
      elseif #rows == 0 then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      self.version = rows[1]
    end,

    GET = function(self, dao_factory, helpers)
      return helpers.responses.send_HTTP_OK(self.version)
    end,

    PATCH = function(self, dao_factory)
      crud.patch(self.params, dao_factory.versions, self.version)
    end,

    DELETE = function(self, dao_factory)
      crud.delete(self.version, dao_factory.versions)
    end
  }
}
