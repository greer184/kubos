local getenv = require('os').getenv
local uv = require 'uv'

local cbor_message_protocol = require 'cbor-message-protocol'
local file_protocol = require 'file-protocol'

local server = uv.new_udp()
local service_port = getenv 'PORT'
service_port = service_port and tonumber(service_port) or 7000
assert(server:bind('127.0.0.1', service_port))

-- Map from channel_id/hash to {ip,port}
local addrs = {}

-- Expire address table entries after a period of inactivity
local timer = uv.new_timer()
timer:start(1000 * 60, 1000 * 60, function ()
  local new_addrs = {}
  local expire = uv.now() - 60 * 60 * 1000
  for k, v in pairs(addrs) do
    if v[3] > expire then
      new_addrs[k] = v
    end
  end
  addrs = new_addrs
end)
timer:unref()

local protocol

local function on_message(message, addr)
  coroutine.wrap(function ()
    local success, error = xpcall(function ()
      assert(type(message) == 'table' and #message > 0)
      addrs[message[1]] = { addr.ip, addr.port, uv.now() }
      protocol.on_message(message)
    end, debug.traceback)
    if not success then
      print(error)
    end
  end)()
end

local send_message = cbor_message_protocol(server, on_message, true)

local function send(channel_id, ...)
  local message = {channel_id, ...}
  local addr = addrs[channel_id]
  if not addr then
    print('Unknown receiver address: ' .. addr)
    return
  end
  local ip, port = unpack(addr)
  addrs[channel_id][3] = uv.now()
  send_message(message, ip, port)
end

protocol = file_protocol(send, 'storage')

require('uv').run()
