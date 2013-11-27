----------------------------------------------------------------------------
-- LuaSec 0.8
-- Copyright (C) 2009-2019 PUC-Rio
--
-- Author: Pablo Musa
-- Author: Tomas Guisasola
---------------------------------------------------------------------------

local socket = require("socket")
local ssl    = require("ssl")
local ltn12  = require("ltn12")
local http   = require("socket.http")
local url    = require("socket.url")

local try    = socket.try

--
-- Module
--
local _M = {
  _VERSION   = "0.8",
  _COPYRIGHT = "LuaSec 0.8 - Copyright (C) 2009-2019 PUC-Rio",
  PORT       = 443,
  TIMEOUT    = 60
}

-- TLS configuration
local cfg = {
  protocol = "any",
  options  = {"all", "no_sslv2", "no_sslv3", "no_tlsv1"},
  verify   = "none",
}

--------------------------------------------------------------------
-- Auxiliar Functions
--------------------------------------------------------------------

-- Insert default HTTPS port.
local function default_https_port(u)
   return url.build(url.parse(u, {port = _M.PORT}))
end

-- Convert an URL to a table according to Luasocket needs.
local function urlstring_totable(url, body, result_table)
   url = {
      url = default_https_port(url),
      method = body and "POST" or "GET",
      sink = ltn12.sink.table(result_table)
   }
   if body then
      url.source = ltn12.source.string(body)
      url.headers = {
         ["content-length"] = #body,
         ["content-type"] = "application/x-www-form-urlencoded",
      }
   end
   return url
end

-- Forward calls to the real connection object.
local function reg(conn)
   local mt = getmetatable(conn.sock).__index
   for name, method in pairs(mt) do
      if type(method) == "function" then
         conn[name] = function (self, ...)
                         return method(self.sock, ...)
                      end
      end
   end
end

-- Return a function which performs the SSL/TLS connection.
local function tcp(params)
    params = params or {}
    -- Default settings
    for k, v in pairs(cfg) do
       params[k] = params[k] or v
    end
    -- Force client mode
    params.mode = "client"
    -- 'create' function for LuaSocket
    return function ()
        local conn = {}
        conn.sock = try(socket.tcp())
        local st = getmetatable(conn.sock).__index.settimeout
        function conn:settimeout(...)
            return st(self.sock, ...)
        end
        -- Replace TCP's connection function
        function conn:connect(host, port)
            if params.https_proxy then
                self.sock:settimeout(1)
                local proxy = params.https_proxy
                try(self.sock:connect(proxy.host, proxy.port or 443))
                self.sock:send(string.format("CONNECT %s:%s HTTP/1.1\r\nHost: %s\r\n%s\r\n", host, port, host,
                                                (proxy.user and string.format("Proxy-Authorization: Basic %s\r\n", mime.b64(proxy.user..":"..proxy.password))) or ""))
                local timeout = socket.gettime() + .3
                local sCode, sPhrase
                while socket.gettime() < timeout do
                    local ok, err = self.sock:receive("*l")
                    if ok then
                        if sCode and sCode >= 200 and ok == "" then break end
                        sCode, sPhrase = ok:match("HTTP/1.[01] (%d%d%d) ?(.*)")
                        sCode = tonumber(sCode)
                    elseif err == "closed" then
                        return nil, "closed"
                    end
                end
                if sCode and sCode >= 300 then
                    return nil, ("Could not create (proxied) connection"..(sCode and (": "..sCode.." "..sPhrase..".")) or ".")
                end
            else
                try(self.sock:connect(host, port))
            end
            self.sock = try(ssl.wrap(self.sock, params))
            self.sock:sni(host)
            try(self.sock:dohandshake())
            reg(self, getmetatable(self.sock))
            return 1
        end
        return conn
    end
end

--------------------------------------------------------------------
-- Main Function
--------------------------------------------------------------------

-- Make an HTTP request over secure connection. This function receives
--  the same parameters of LuaSocket's HTTP module (except 'proxy' and
--  'redirect') plus LuaSec parameters.
--
-- @param url mandatory (string or table)
-- @param body optional (string)
-- @return (string if url == string or 1), code, headers, status
--
local function request(url, body)
  local result_table = {}
  local stringrequest = type(url) == "string"
  if stringrequest then
    url = urlstring_totable(url, body, result_table)
  else
    url.url = default_https_port(url.url)
  end
  if http.PROXY or url.proxy then
    return nil, "proxy not supported; try https_proxy instead"
  elseif url.redirect then
    return nil, "redirect not supported"
  elseif url.create then
    return nil, "create function not permitted"
  end
  -- New 'create' function to establish a secure connection
  url.create = tcp(url)
  local res, code, headers, status = http.request(url)
  if res and stringrequest then
    return table.concat(result_table), code, headers, status
  end
  return res, code, headers, status
end

--------------------------------------------------------------------------------
-- Export module
--

_M.request = request
_M.tcp = tcp

return _M
