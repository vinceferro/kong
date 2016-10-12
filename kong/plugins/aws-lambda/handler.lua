-- Copyright (C) Mashape, Inc.

local BasePlugin = require "kong.plugins.base_plugin"
local access = require "kong.plugins.aws-lambda.access"

local AWSLambdaHandler = BasePlugin:extend()

function AWSLambdaHandler:new()
  AWSLambdaHandler.super.new(self, "basic-auth")
end

function AWSLambdaHandler:access(conf)
  AWSLambdaHandler.super.access(self)
  access.execute(conf)
end

AWSLambdaHandler.PRIORITY = 750

return AWSLambdaHandler
