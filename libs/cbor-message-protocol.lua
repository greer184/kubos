--[[
Copyright (C) 2018 Kubos Corporation
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
  http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]

--[[lit-meta
  name = "kubos/cbor-message-protocol"
  version = "0.0.2"
  description = "Simple protocol for streaming CBOR messages with backpressure over UDP"
  tags = { "kubos", "udp", "cbor", "backpressure"}
  author = { name = "Tim Caswell", email = "tim@kubos.co" }
  homepage = "https://github.com/kubos/kubos"
  dependencies = {
    "creationix/cbor",
    "creationix/defer",
  }
  license = "Apache 2.0"
]]

local function makeCallback()
  local thread = coroutine.running()
  return function (err, value, ...)
    if err then
      assert(coroutine.resume(thread, nil, err))
    else
      assert(coroutine.resume(thread, value == nil and true or value, ...))
    end
  end
end

local function wrapper(fn)
  return function (...)
    local args = { ... }
    return coroutine.wrap(function()
      local success, result = xpcall(function ()
        return fn(unpack(args))
      end, debug.traceback)
      if not success then
        print(result)
      end
    end)()
  end
end

local cbor = require 'cbor'
local defer = require 'defer'
local byte = string.byte
local uv = require 'uv'

local function sleep(ms)
  local timer = uv.new_timer()
  local co = coroutine.running()
  timer:start(ms, 0, function ()
    return coroutine.resume(co)
  end)
  return coroutine.yield()
end

return function (handle, on_message, log_messages)
  local paused = false
  local write_queue = {}

  local function resume()
    if not paused then return end
    paused = false
    while not paused and #write_queue > 0 do
      local co = table.remove(write_queue, 1)
      local success, result = xpcall(function ()
        return coroutine.resume(co)
      end, debug.traceback)
      if not success then
        print(result)
      end
    end
  end

  -- TODO: make key weak reference
  local handle_waiters = {}
  local function wait_flush(udp)
    local co = coroutine.running()
    local list = handle_waiters[udp]
    if not list then
      list = {}
      handle_waiters[udp] = list
    end
    list[#list + 1] = co
    return coroutine.yield()
  end
  local timer = uv.new_timer()
  timer:start(100, 100, function ()
    for udp, list in pairs(handle_waiters) do
      if udp:get_send_queue_count() == 0 then
        handle_waiters[udp] = nil
        for i = 1, #list do
          defer(function ()
            return coroutine.resume(list[i])
          end)
        end
      end
    end
  end)

  local function send_message(message, host, port)
    if paused then
      write_queue[#write_queue + 1] = coroutine.running()
      coroutine.yield()
    end
    if log_messages then p('->', message) end
    handle:send('\x00' .. cbor.encode(message), host, port, makeCallback())
    return coroutine.yield()
  end

  local function send_pause(host, port)
    if log_messages then p '-> pause' end
    handle:send('\x01', host, port, makeCallback())
    return coroutine.yield()
  end

  local function send_resume(host, port)
    if log_messages then p '-> resume' end
    handle:send('\x02', host, port, makeCallback())
    return coroutine.yield()
  end

  handle:recv_start(wrapper(function (err, data, addr)
    assert(not err, err)
    if not data then return end
    local control = byte(data, 1)
    if control == 1 then
      if log_messages then p '<- pause' end
      paused = true
      return
    elseif control == 2 then
      if log_messages then p '<- resume' end
      return defer(resume)
    elseif control ~= 0 then
      return print("Ignoring unknown control frame: " .. control)
    end
    local message = cbor.decode(data, 2)
    if log_messages then p('<-', message) end
    return on_message(message, addr)
  end))

  return send_message, send_pause, send_resume
end
