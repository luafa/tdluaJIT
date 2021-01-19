--[[
TDLuaJIT - pure lua interface with tdlib usign FFI - LuaJIT
tdlua.lua
© Giuseppe Marino 2019 see LICENSE
@ Pouya Poorrahman 2021 Developed
--]]
local yield   = coroutine.yield
local loop = {}
local mt = {}
local tdlua = {}
local mt2 = {}
local ffi = require 'ffi'
local json = require 'cjson'
local C = ffi.C
local lds = {}
local function vardump(value, depth, key) local linePrefix = "" local spaces = "" if key ~= nil then linePrefix = "["..key.."] = " end if depth == nil then depth = 0 else depth = depth + 1 for i=1, depth do spaces = spaces .. " " end end if type(value) == 'table' then mTable = getmetatable(value) if mTable == nil then print(spaces ..linePrefix.."(table) ") else print(spaces .."(metatable) ") value = mTable end for tableKey, tableValue in pairs(value) do vardump(tableValue, depth, tableKey) end elseif type(value) == 'function' or type(value) == 'thread' or type(value) == 'userdata' or value == nil then print(spaces..tostring(value)) else print(spaces..linePrefix.."("..type(value)..") "..tostring(value)) end end 
ffi.cdef([[
void *memmove(void *dst, const void *src, size_t len);
]])
function lds.error( msg )
    error( msg )
end
function lds.assert( x, msg )
    if not x then lds.error(msg) end
end
local function simple_deep_copy( x )
    if type(x) ~= 'table' then return x end
    local t = {}
    for k, v in pairs(x) do
        t[k] = simple_deep_copy(v)
    end
    return t
end
lds.simple_deep_copy = simple_deep_copy
lds.int32_t  = ffi.typeof('int32_t')
lds.uint32_t = ffi.typeof('uint32_t')
lds.size_t   = ffi.typeof('size_t')
lds.INT_MAX = tonumber( lds.uint32_t(-1) / 2 )
lds.INT32_MAX = tonumber( lds.uint32_t(-1) / 2 )
lds = lds
ffi.cdef([[
void * malloc(size_t size);
void * calloc(size_t count, size_t size);
void * valloc(size_t size);
void * realloc(void *ptr, size_t size);
void free(void *ptr);
]])
local MallocAllocatorT__mt = {
    __index = {
        allocate  = function(self, n)
            return C.calloc( n, self._ct_size )
        end,
        deallocate = function(self, p)
            if p ~= 0 then C.free(p) end
        end,
        reallocate = function(self, p, n)
            return C.realloc(p, n)
        end,
    }
}
function lds.MallocAllocatorT( ct, which )
    if type(ct) ~= 'cdata' then error('argument 1 is not a valid "cdata"') end
    local t_mt = lds.simple_deep_copy(MallocAllocatorT__mt)
    t_mt.__index._ct = ct
    t_mt.__index._ct_size = ffi.sizeof(ct)

    if which == nil or which == 'calloc' then
    elseif which == 'malloc' then
        t_mt.__index.allocate = function(self, n)
            return C.malloc( n * self._ct_size )
        end
    elseif which == 'valloc' then
        t_mt.__index.allocate = function(self, n)
            return C.malloc( n * self._ct_size )
        end
    else
        error('argument 2 must be nil, "calloc", "malloc", or "valloc"')
    end

    local t_anonymous = ffi.typeof( 'struct {}' )
    return ffi.metatype( t_anonymous, t_mt )
end
function lds.MallocAllocator( ct, which )
    return lds.MallocAllocatorT( ct, which )()
end
local VLAAllocator__anchors = {}
VLAAllocatorT__mt = {
    __index = {
        allocate  = function(self, n)
            local vla = ffi.new( self._vla, n )
            VLAAllocator__anchors[tostring(ffi.cast(lds.size_t, vla._data))] = vla
            return vla._data
        end,
        deallocate = function(self, p)
            -- remove the stored reference and then let GC do the rest
            if p ~= nil then
                VLAAllocator__anchors[tostring(ffi.cast(lds.size_t, p))] = nil
            end
        end,
        reallocate = function(self, p, n)
            if p == nil then
                local vla = ffi.new( self._vla, n )
                VLAAllocator__anchors[tostring(ffi.cast(lds.size_t, vla._data))] = vla
                return vla._data
            else
                local key_old = tostring(ffi.cast(lds.size_t, p))
                local vla_old = VLAAllocator__anchors[key_old]

                local vla_new = ffi.new( self._vla, n )
                local key_new = tostring(ffi.cast(lds.size_t, vla_new._data))

                VLAAllocator__anchors[key_new] = vla_new
                ffi.copy(vla_new._data, p, ffi.sizeof(vla_old))
                VLAAllocator__anchors[key_old] = nil
                return vla_new._data
            end
        end,
    }
}
function lds.VLAAllocatorT( ct )
    if type(ct) ~= 'cdata' then error('argument 1 is not a valid "cdata"') end
    local t_mt = lds.simple_deep_copy(VLAAllocatorT__mt)
    t_mt.__index._ct = ct
    t_mt.__index._ct_size = ffi.sizeof(ct)
    t_mt.__index._vla = ffi.typeof( 'struct { $ _data[?]; }', ct )

    local t_anonymous = ffi.typeof( 'struct {}' )
    return ffi.metatype( t_anonymous, t_mt )
end
function lds.VLAAllocator( ct )
    return lds.VLAAllocatorT( ct )()
end
local success, J =  pcall(function() return require 'lds/jemalloc' end)
if success and J then

    lds.J = J

    local JemallocAllocatorT__mt = {
        __index = {
            allocate  = function(self, n)
                return J.mallocx( n * self._ct_size, self._flags )
            end,
            deallocate = function(self, p)
                if p ~= nil then J.dallocx(p, self._flags) end
            end,
            reallocate = function(self, p, n)
                if p == nil then
                    return J.mallocx( n * self._ct_size, self._flags )
                else
                    return J.rallocx(p, n, self._flags)
                end
            end,
        }
    }

    function lds.JemallocAllocatorT( ct, flags )
        if type(ct) ~= 'cdata' then error("argument 1 is not a valid 'cdata'") end
        local t_mt = lds.simple_deep_copy(JemallocAllocatorT__mt)
        t_mt.__index._ct = ct
        t_mt.__index._ct_size = ffi.sizeof(ct)
        t_mt.__index._flags = flags or J.MALLOCX_ZERO()

        local t_anonymous = ffi.typeof( "struct {}" )
        return ffi.metatype( t_anonymous, t_mt )
    end
    function lds.JemallocAllocator( ct, flags )
        return lds.JemallocAllocatorT( ct, flags )()
    end

end
lds = lds
local QueueT_cdef = [[
struct {
    $   *a;
    int alength;
    int j;
    int n;
}
]]
local function QueueT__resize( q, reserve_n )
    local blength = math.max( 1, reserve_n or (2 * q.n) )
    if q.alength >= blength then return end

    local new_data = q.__alloc:reallocate(q.a, blength *q._ct_size)
    q.a = ffi.cast(q.a, new_data)
    q.alength = blength
end
local QueueT_mt = {

    __new = function( qt )
        return ffi.new( qt, {
            a = qt.__alloc:allocate( 1 * qt._ct_size ),
            alength = 1,
            n = 0,
            j = 0,
        })
    end,

    __gc = function( self )
        self.__alloc:deallocate( self.a )
    end,

    __len = function( self )
        return self.n
    end,

    __index = {

        size = function( self )
            return self.n
        end,

        capacity = function( self )
            return math.floor( self.alength / self._ct_size )
        end,

        reserve = function( self, n )
            QueueT__resize( self, n )
        end,

        empty = function( self )
            return self.n == 0
        end,

        get_front = function( self )
            lds.assert( self.n ~= 0, "get_front: Queue is empty" )
            return self.a[self.j]
        end,

        get_back = function( self )
            lds.assert( self.n ~= 0, "get_back: Queue is empty" )
            local idx = (self.j + (self.n - 1)) % self.alength
            return self.a[idx]
        end,

        push = function( self, x )
            if self.n + 1 > self.alength then QueueT__resize(self) end
            self.a[(self.j+self.n) % self.alength] = x
            self.n = self.n + 1
            return true
        end,

        pop = function( self )
            lds.assert( self.n ~= 0, "pop_front: Queue is empty" )
            local x = self.a[self.j]
            self.j = (self.j + 1) % self.alength
            self.n = self.n - 1
            if self.alength >= (3 * self.n) then QueueT__resize(self) end
            return x
        end,

        clear = function( self )
            self.n = 0
            self.j = 0
        end,
    },
}
function lds.QueueT( ct )
    if type(ct) ~= 'cdata' then error("argument 1 is not a valid 'cdata'") end

    -- clone the metatable and insert type-specific data
    local qt_mt = lds.simple_deep_copy(QueueT_mt)
    qt_mt.__index._ct = ct
    qt_mt.__index._ct_size = ffi.sizeof(ct)
    qt_mt.__index.__alloc = lds.MallocAllocator(ct)

    local qt = ffi.typeof( QueueT_cdef, ct )
    return ffi.metatype( qt, qt_mt )
end
function lds.Queue( ct )
    return lds.QueueT( ct )()
end
queue = lds.Queue
ffi.cdef[[
void* td_json_client_create ();
void td_json_client_send (void *client, const char *request);
const char* td_json_client_receive (void *client, double timeout);
const char* td_json_client_execute (void *client, const char *request);
void td_json_client_destroy (void *client);
void td_set_log_verbosity_level(int new_verbosity_level);
]]
local buffer_t = ffi.typeof(queue(ffi.typeof"char*"))
local tdlua_t = [[
struct {
    void* client;
    $ updatesBuffer;
    bool ready;
}
]]
local function old2new(obj)
    for k, v in pairs(obj) do
        if type(v) == 'table' then
            old2new(v)
        end
        if k == '_' and not obj['@type'] then
            obj['@type'] = v
            obj._ = nil
        end
    end
    return obj
end
local function pushUpdateBuffer(buffer, update)
    local jupd = json.encode(update)
    local cstr = ffi.C.malloc(#jupd+1)
    ffi.copy(cstr, jupd)
    buffer:push(cstr)
end
local function popUpdateBuffer(buffer)
    local cstr = buffer:pop()
    local jupd = ffi.string(cstr)
    ffi.C.free(cstr)
    return json.decode(jupd)
end
local tdlib = ffi.load('./libtdjson.so')
tdlib.td_set_log_verbosity_level(0)
function tdlua.send(self, request)
    tdlib.td_json_client_send(self.client, json.encode(old2new(request)))
end
function tdlua.execute(self, request, timeout)
    timeout = tonumber(timeout) or 10
    local nonce = math.random(0, 0xFFFFFFFF)
    local extra = {
        nonce = nonce,
        extra = request['@extra']
    }
    extra = request['@extra']
    request['@extra'] = nonce
    self:send(request)

    local start = os.time()

    while os.time() - start < timeout do
        local update = self:rawReceive(timeout)
        if update['@extra'] == nonce then
            update['@extra'] = extra
            return update
        end
        pushUpdateBuffer(self.updatesBuffer, update)
    end

end

function tdlua.rawExecute(self, request)
    local resp = ffi.string(tdlib.td_json_client_execute(self.client, json.encode(old2new(request))))
    return old2new(json.decode(resp))
end

function tdlua.rawReceive(self, timeout)
   local resp = tdlib.td_json_client_receive(self.client, timeout or 10)
   if resp == nil then
       return
   end
   return old2new(json.decode(ffi.string(resp)))
end

function tdlua.receive(self, timeout)
    ---[[
    if not self.updatesBuffer:empty()  then
        return popUpdateBuffer(self.updatesBuffer)
    end
    --]]

    return self:rawReceive(timeout)
end

function tdlua.destroy(self)
    print 'destory called'
    if self.ready then
        print 'client is ready, closing'
        self:send({_='close'})
        while self.ready do
            local update = self:rawReceive()
            pushUpdateBuffer(self.updatesBuffer, update)
            self:checkAuthState(update)
        end
    end
    tdlib.td_json_client_destroy(self.client)
end

function tdlua.checkAuthState(self, update)
    if update['@type'] == 'updateAuthorizationState' then
        if not self.ready and update['authorization_state']['@type'] == 'authorizationStateReady' then
            --TODO load updates buffer
            self.ready = true
        elseif update['authorization_state']['@type'] == 'authorizationStateClosed' then
            --TODO save updates buffer
            self:emptyUpdatesBuffer()
            self.ready = false
        end
    end
end

function tdlua.emptyUpdatesBuffer(self)
    while not self.updatesBuffer:empty() do
        popUpdateBuffer(updatesBuffer)
    end
end
function mt2.__new(self)
    self = ffi.new(self)
    self.client = tdlib.td_json_client_create();
    return self
end
function mt2.__gc(self)
    self:destroy()
end
mt2.__index = tdlua
tdlua = ffi.metatype(ffi.typeof(tdlua_t, buffer_t), mt2)
function loop:new(instance, callback)
    local i = {instance = instance, callback = callback, upd_id = 0, upd_cb = {}, threads = {}}
    table.insert(self.instances, i)
    setmetatable(i, {__index = self})
    callback(i)
    return i
end

function loop:loop()
    while true do
        for _, i in ipairs(self.instances) do
            local instance = i.instance
            local callback = i.callback
            local upd_cb   = i.upd_cb
            local update   = instance:rawReceive(1)
            local threads  = i.threads
            if not update then
                goto continue
            end

            local extra = update['@extra']
            update['@extra'] = nil
            if extra and upd_cb[extra] then
                local cb = upd_cb[extra]
                if type(cb) == 'function' then
                    cb(self, update)
                else
                    coroutine.resume(cb, self, update)
                    table.insert(threads, cb)
                end
                upd_cb[extra] = nil
                goto continue
            end

            callback(update)

            self:runCoros()

            ::continue::
        end
    end
end

function loop:send(request)
    return self.instance:send(request)
end

function loop:receive(request, timeout)
    timeout = tonumber(timeout) or 1
    return self.instance:rawReceive(request, timeout)
end

function loop:execute(request, callback)
    print ('execute', callback)
    if not type(request) == 'table' then
        if type(request) == 'function' or type(params) == 'thread' then
            callback = request
        end
        request = {}
    end
    if type(callback) == 'function' or type(params) == 'thread' then
        self.upd_id = self.upd_id +1
        request['@extra'] = self.upd_id
        self.upd_cb[self.upd_id] = callback
        self.instance:send(request)
    end
end

function loop:rawExecute(request)
    self.instance:rawExecute(request)
end
function loop:runCoros()
    local threads = self.threads
    for k, v in pairs(threads) do
        local status = coroutine.status(v)
        if status == 'dead' then
            table.remove(threads, k)
        elseif status == 'suspended' then
            coroutine.resume(v)
        end
    end
end
loop.instances = {}
function mt.__index(self, method)
    return function(instance, ...)
        local params, callback = ...
        if not type(params) == 'table' then
            if type(params) == 'function' or type(params) == 'thread' then
                callback = params
            end
            params = {}
        end
        params._ = method
        return instance:execute(params, callback)
    end
end
loop = setmetatable(loop, mt)
local function callback(datas)
    while true do
        local update = yield()
        vardump(update)
    end
end
client = tdlua()
local i = loop:new(client, coroutine.wrap(callback))
i:loop()
