local socket = require("socket")

local rpc = {}

-- create a method based on its interface definition
local method = function(name, method_interface)
  local m = {}
  local list_types = function(direction)
    local results = {}
    for _, arg in ipairs(method_interface.args or {}) do
      if string.match(arg.direction, direction) then
        results[#results + 1] = arg.type
      end
    end
    return results
  end
  m.result_types = function()
    local types = list_types("out")
    if method_interface.resulttype and method_interface.resulttype ~= "void" then
      table.insert(types, 1, method_interface.resulttype)
    end
    return types
  end
  m.arg_types = function()
    return list_types("in")
  end
  m.serialize_call = function(...)
    local args = {...}
    local arg_types = m.arg_types()
    table.insert(args, 1, name)
    table.insert(arg_types, 1, string)
    return rpc.serialize_list(arg_types, args)
  end
  m.serialize_result = function(...)
    local results = {...}
    local result_types = m.result_types()
    return rpc.serialize_list(result_types, results)
  end
  return m
end

-- the interface metatable defines the metamethods for a interface
local interface_mt = {
  __index = function(o, method_name)
    local m = o.__methods[method_name]
    if m then return method(method_name, m) end
  end
}

-- function to load new interfaces
rpc.interface = function(args)
  local interface = {__name=args.name, __methods=args.methods}
  setmetatable(interface, interface_mt)
  return interface
end

-- serialization functions
rpc.serialize = function(arg_type, arg)
  if arg_type == "string" and type(arg) ~= "string" then
    error("String expected")
  elseif arg_type == "char" and (type(arg) ~= "string" or #arg ~= 1) then
    error("Char expected")
  elseif arg_type == "double" and (type(arg) ~= "number") then
    error("Double expected")
  end
  return (string.gsub((string.gsub(arg, "\\", "\\\\")), "\n", "\\n"))
end

rpc.deserialize = function(arg_type, arg)
  if arg_type == "double" then
    return tonumber(arg)
  else
    return (string.gsub(
              string.gsub(
                string.gsub(arg, "^\\n", "\n"),
              "([^\\])\\n", "%1\n"),
            "\\\\", "\\"))
  end
end

rpc.serialize_list = function(arg_types, args)
  if #args ~= #arg_types then
    error("Wrong number of arguments (" .. #args .. " instead of " .. #arg_types .. ")")
  end
  local lines = {}
  for i, t in ipairs(arg_types) do
    lines[#lines + 1] = rpc.serialize(t, args[i])
  end
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end


--- proxy functions
local proxy_call = function(proxy, method_name)
  return function(...)
    local method = proxy.interface[method_name]
    if method == nil then
      error("Invalid method")
    end
    proxy.client:send(method.serialize_call(...))
    local results = {}
    local result_types = method.result_types()
    for i in ipairs(result_types) do
      line, err = proxy.client:receive()
      err = err or string.match(line, "^___ERRORPC: (.*)$")
      if err then
        error("RPC error: " .. err)
      end
      results[#results + 1] = rpc.deserialize(result_types[i], line)
    end
    return unpack(results)
  end
end

local proxy_mt = {
  __index = proxy_call
}

rpc.create_proxy_from_interface = function(ip, port, interface)
  local client = assert(socket.connect(ip, port))
  client:settimeout(5)
  local proxy = {interface=interface, client=client}
  setmetatable(proxy, proxy_mt)
  return proxy
end

-- server functions
local exec_procedure = function(client, method, implementation)
  local arg_types = method.arg_types()
  args = {}
  for i in ipairs(arg_types) do
    line = client:receive()
    args[#args + 1] = rpc.deserialize(arg_types[i], line)
  end
  local results = {implementation(unpack(args))}
  local result_str = rpc.serialize_list(method.result_types(), results)
  client:send(result_str)
end

local serve_client = function(servant)
  local server = servant.server
  local client, err = server:accept()
  if err then
    -- TODO: untested. handle timeout
    return
  end
  local method_name, err = client:receive()
  if err then
    -- TODO: untested
    client:send("___ERRORPC: Unknown error: " .. err .. "\n")
    client:close()
    return
  end
  local method = servant.interface[method_name]
  if method == nil then
    -- TODO: untested
    client:send("___ERRORPC: Unknown command '" .. (method_name or "") .. "'\n")
    client:close()
    return
  end
  local implementation = servant.implementation[method_name]
  if implementation == nil then
    -- TODO: untested
    client:send("___ERRORPC: Command '" .. (method_name or "") .. " not implementated'\n")
    client:close()
    return
  end
  status, err = pcall(function() exec_procedure(client, method, implementation) end)
  if not status then
    -- TODO: untested
    client:send("___ERRORPC: Unknown error: '" .. err .. "'\n")
    client:close()
    return
  end
end

rpc.create_servant_from_interface = function(implementation, interface)
  local server = assert(socket.bind("*", 0))
  server:settimeout(1)
  local ip, port = server:getsockname()
  local s = {
    interface=interface,
    serve_client=serve_client,
    implementation=implementation,
    ip=ip,
    port=port,
    server=server
  }
  setmetatable(s, {__index = function(o, method_name) return o.server[method_name] end })
  return s
end

-- public methods - untested
rpc.createproxy = function(IP, port, interface_file)
  local int
  interface = function(x)
    int = rpc.interface(x)
  end
  assert(loadfile(interface_file))()
  return rpc.create_proxy_from_interface(IP, port, int)
end

local servants = {}
rpc.createServant = function(implementation, interface_file)
  local int
  interface = function(x)
    int = rpc.interface(x)
  end
  assert(loadfile(interface_file))()
  servant = rpc.create_servant_from_interface(implementation, int)
  servants[#servants + 1] = servant
  return servant
end

rpc.waitIncoming = function()
  while true do
    for _, servant in ipairs(servants) do
      servant:serve_client()
    end
  end
end

return rpc