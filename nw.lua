
--native widgets - frontend.
--Written by Cosmin Apreutesei. Public domain.

local ffi = require'ffi'
local glue = require'glue'
local box2d = require'box2d'
require'strict'

local nw = {}

--helpers --------------------------------------------------------------------

local assert = glue.assert --assert with string.format

local function indexof(dv, t)
	for i,v in ipairs(t) do
		if v == dv then return i end
	end
end

--backends -------------------------------------------------------------------

--default backends for each OS
nw.backends = {
	Windows = 'nw_winapi',
	OSX     = 'nw_cocoa',
}

function nw:init(bkname)
	if self.backend then
		if bkname then
			assert(self.backend.name == bkname, 'already initialized to %s', self.backend.name)
		end
		return
	end
	bkname = bkname or assert(self.backends[ffi.os], 'unsupported OS %s', ffi.os)
	self.backend = require(bkname)
	assert(self:os(self.backend.min_os), 'unsupported OS %s < %s', self:os(), self.backend.min_os)
	self.backend.frontend = self
end

--os version -----------------------------------------------------------------

--check if ver2 >= ver1, where ver1 and ver2 have the form 'name maj.min....'.
local function check_version(ver1, ver2)
	ver1 = ver1:lower()
	ver2 = ver2:lower()
	local os1, v1 = ver1:match'^([^%s]+)(.*)'
	local os2, v2 = ver2:match'^([^%s]+)(.*)'
	if not os1 then return false end     --empty string or starts with spaces
	if os1 ~= os2 then return false end  --different OS
	v1 = v1:match'^%s*(.*)'
	v2 = v2:match'^%s*(.*)'
	if v1 == v2 then
		return true          --shortcut: equal version strings.
	end
	while v1 ~= '' do       --while there's the next part of ver1 to check...
		if v2 == '' then     --there's no next part of ver2 to check against.
			return false
		end
		local p1, p2         --part prefix (eg. SP3)
		local n1, n2         --part number
		p1, n1, v1 = v1:match'^([^%.%d]*)(%d*)%.?(.*)' --eg. 'SP3.0' -> 'SP', '3', '0'
		p2, n2, v2 = v2:match'^([^%.%d]*)(%d*)%.?(.*)'
		assert(p1 ~= '' or n1 ~= '', 'invalid syntax') --ver1 part is a dot.
		assert(p2 ~= '' or n2 ~= '', 'invalid syntax') --ver2 part is a dot.
		if p1 ~= '' and p1 ~= p2 then
			return false      --prefixes don't match.
		end
		if n1 ~= '' then     --above checks imply n2 ~= '' also.
			local n1 = tonumber(n1)
			local n2 = tonumber(n2)
			if n1 ~= n2 then  --version parts are different, decide now.
				return n2 > n1
			end
		end
	end
	return true             --no more parts of v1 to check.
end

local osver
local osver_checks = {}    --cached version checks

function nw:os(ver)
	osver = osver or self.backend:os()
	if ver then
		local check = osver_checks[ver]
		if check == nil then
			check = check_version(ver, osver)
			osver_checks[ver] = check
		end
		return check
	else
		return osver
	end
end

--oo -------------------------------------------------------------------------

local object = {}

--poor man's overriding sugar. usage:
--		win:override('mousemove', function(self, inherited, x, y)
--			inherited(self, x, y)
--		end)
function object:override(name, func)
	local inherited = self[name]
	self[name] = function(self, ...)
		return func(self, inherited, ...)
	end
end

function object:dead()
	return self._dead or false
end

function object:_check()
	assert(not self._dead, 'dead object')
end

--create a read/write property that is implemented via a getter and setter in the backend.
function object:_property(name)
	local getter = 'get_'..name
	local setter = 'set_'..name
	self[name] = function(self, on)
		self:_check()
		if on == nil then
			return self.backend[getter](self.backend)
		else
			self.backend[setter](self.backend, on)
		end
	end
end

--events ---------------------------------------------------------------------

--register an observer to be called for a specific event
function object:observe(event, func)
	self.observers = self.observers or {} --{event = {func = true, ...}}
	self.observers[event] = self.observers[event] or {}
	self.observers[event][func] = true
end

--handle a query event by calling its event handler
function object:_handle(event, ...)
	if self._events_disabled then return end
	if not self[event] then return end
	return self[event](self, ...)
end

--fire an event, i.e. call observers and create a meta event 'event'
function object:_fire(event, ...)
	if self._events_disabled then return end
	--call any observers
	if self.observers and self.observers[event] then
		for obs in pairs(self.observers[event]) do
			obs(self, ...)
		end
	end
	--fire the meta-event 'event'
	if event ~= 'event' then
		self:_event('event', event, ...)
	end
end

--handle and fire a non-query event.
function object:_event(event, ...)
	self:_handle(event, ...)
	self:_fire(event, ...)
end

--handle and fire a query event.
function object:_query(event)
	local allow = self:_handle(event) ~= false
	self:_fire(event, allow)
	return allow
end

--enable or disable events. returns the old state.
function object:events(enabled)
	local old = not self._events_disabled
	self._events_disabled = not enabled
	return old
end

--app object -----------------------------------------------------------------

local app = glue.update({}, object)

--return the singleton app object.
--load a default backend on the first call if no backend was set by the user.
function nw:app()
	if not self._app then
		if not self.backend then
			self:init()
		end
		self._app = app:_new(self, self.backend.app)
	end
	return self._app
end

function app:_new(nw, backend_class)
	self = glue.inherit({nw = nw}, self)
	self._running = false
	self._windows = {} --{window1, ...}
	self._notifyicons = {} --{icon = true}
	self._autoquit = true --quit after the last window closes
	self._ignore_numlock = false --ignore the state of the numlock key on keyboard events
	self.backend = backend_class:new(self)
	return self
end

--message loop ---------------------------------------------------------------

--start the main loop
function app:run()
	if self._running then return end --ignore while running
	self._running = true --run() barrier
	self.backend:run()
	self._running = false
	self._stopping = false --stop() barrier
end

function app:running()
	return self._running
end

function app:stop()
	if not self._running then return end --ignore while not running
	if self._stopping then return end --ignore repeated attempts
	self._stopping = true
	self.backend:stop()
end

--quitting -------------------------------------------------------------------

function app:autoquit(autoquit)
	if autoquit == nil then
		return self._autoquit
	else
		self._autoquit = autoquit
	end
end

--ask the app and all windows if they can quit. need unanimous agreement to quit.
function app:_canquit()
	self._quitting = true --quit() barrier

	local allow = self:_query'quitting'

	for i,win in ipairs(self:windows()) do
		if not win:dead() and not win:parent() then
			allow = win:_canclose() and allow
		end
	end

	self._quitting = nil
	return allow
end

function app:_forcequit()
	self._quitting = true --quit() barrier

	for i,win in ipairs(self:windows()) do
		if not win:dead() and not win:parent() then
			win:_forceclose()
		end
	end

	if self:window_count() == 0 then --no windows created while closing
		--free notify icons otherwise they hang around (both in XP and in OSX).
		self:_free_notifyicons()
		self:_free_dockicon()
		self:stop()
	end

	self._quitting = nil
end

function app:quit()
	if self._quitting then return end --ignore if already quitting
	if not self._running then return end --ignore if not running
	if self:_canquit() then
		self:_forcequit()
	end
end

function app:_backend_quitting()
	self:quit()
end

--time -----------------------------------------------------------------------

function app:time()
	return self.backend:time()
end

function app:timediff(start_time, end_time)
	return self.backend:timediff(start_time, end_time or self:time())
end

--timers ---------------------------------------------------------------------

function app:runevery(seconds, func)
	seconds = math.max(0, seconds)
	self.backend:runevery(seconds, func)
end

function app:runafter(seconds, func)
	self:runevery(seconds, function()
		func()
		return false
	end)
end

--window list ----------------------------------------------------------------

--get existing windows in creation order
function app:windows(order)
	if order == 'zorder' then
		--TODO
	elseif order == '-zorder' then
		--TODO
	else
		return glue.update({}, self._windows) --take a snapshot
	end
end

function app:window_count()
	return #self._windows
end

function app:_window_created(win)
	table.insert(self._windows, win)
	self:_event('window_created', win)
end

function app:_window_closed(win)
	self:_event('window_closed', win)
	table.remove(self._windows, indexof(win, self._windows))
end

--windows --------------------------------------------------------------------

local window = glue.update({}, object)

local defaults = {
	--state
	visible = true,
	minimized = false,
	fullscreen = false,
	maximized = false,
	--frame
	title = '',
	frame = 'normal',
	--behavior
	topmost = false,
	minimizable = true,
	maximizable = true,
	closeable = true,
	resizeable = true,
	fullscreenable = true,
	autoquit = false, --quit the app on closing
	edgesnapping = false,
}

function app:window(t)
	return window:_new(self, self.backend.window, t)
end

local bool_frame = {[false] = 'none', [true] = 'normal'}
local frame_opt = glue.index{'normal', 'none', 'none-transparent', 'toolbox'}

local function checkframe(frame)
	frame = bool_frame[frame] or frame
	assert(frame_opt[frame], 'invalid frame')
	return frame
end

function window:_new(app, backend_class, useropt)

	--check/normalize args.
	local opt = glue.update({}, defaults, useropt)
	opt.frame = checkframe(opt.frame)

	--frameless windows are not resizeable.
	opt.resizeable = (opt.frame == 'normal' or opt.frame == 'toolbox') and opt.resizeable ~= false

	--toolbox windows are topmost by default.
	if useropt.topmost == nil and opt.frame == 'toolbox' then
		opt.topmost = true
	end

	--if missing some frame coords but given some client coords, convert client
	--coords to frame coords, and replace missing frame coords with the result.
	if not opt.x or not opt.y or not opt.w or not opt.h and (opt.cx or opt.cy or opt.cw or opt.ch) then
		local x1, y1, w1, h1 = app:client_to_frame(opt.frame, opt.cx or 0, opt.cy or 0, opt.cw or 0, opt.ch or 0)
		opt.x = opt.x or (opt.cx and x1)
		opt.y = opt.y or (opt.cy and y1)
		opt.w = opt.w or (opt.cw and w1)
		opt.h = opt.h or (opt.ch and h1)
	end

	--width and height must be given, either of the client area or of the frame.
	assert(opt.w, 'w or cw missing')
	assert(opt.h, 'h or ch missing')

	assert((not opt.x) == (not opt.y), 'either give both x and y or none')

	self = glue.inherit({app = app}, self)

	self._mouse = {}
	self._down = {}
	self._views = {}

	self.backend = backend_class:new(app.backend, self, opt)

	--stored properties
	self._parent = opt.parent
	self._frame = opt.frame
	self._minimizable = opt.minimizable
	self._maximizable = opt.maximizable
	self._closeable = opt.closeable
	self._resizeable = opt.resizeable
	self._fullscreenable = opt.fullscreenable
	self._autoquit = opt.autoquit
	self:edgesnapping(opt.edgesnapping)

	--move sticky children along with the parent
	self:observe('resizing', function(self, how, x, y)
		local x0, y0 = self:frame_rect()
		local dx = x - x0
		local dy = y - y0
		for _,win in ipairs(self.app:windows()) do
			if win:sticky() and win:parent() == self then
				local x, y = win:frame_rect()
				win:frame_rect(x + dx, y + dy)
			end
		end
	end)

	self.app:_window_created(self)
	self:_event'created'

	--windows are created hidden to allow proper setup before events start.
	if opt.visible then
		self:show()
	end

	return self
end

--closing --------------------------------------------------------------------

function window:_canclose()
	if self._closing then return false end --reject while closing (from quit() and user quit)

	self._closing = true --_backend_closing() and _canclose() barrier
	local allow = self:_query'closing'
	self._closing = nil
	return allow
end

function window:_forceclose()
	self.backend:forceclose()
end

function window:close()
	if self:_backend_closing() then
		self:_forceclose()
	end
end

function window:_backend_closing()
	if self._closed then return false end --reject if closed
	if self._closing then return false end --reject while closing

	if self:autoquit() or (self.app:autoquit() and self.app:window_count() == 1) then
		self._quitting = true
		return self.app:_canquit()
	else
		return self:_canclose()
	end
end

function window:_backend_closed()
	if self._closed then return end --ignore if closed

	self._closed = true --_backend_closing() and _backend_closed() barrier
	self:_event'closed'
	self:_free_views()
	self.app:_window_closed(self)
	self._dead = true

	if self._quitting then
		self.app:_forcequit()
	end
end

--activation -----------------------------------------------------------------

function app:activate()
	self.backend:activate()
end

function app:active_window()
	return self.backend:active_window()
end

function app:active()
	return self.backend:active()
end

function app:_backend_activated()
	self:_event'activated'
end

function app:_backend_deactivated()
	self:_event'deactivated'
end

function window:activate()
	self:_check()
	if not self:visible() then return end
	self.backend:activate()
end

function window:active()
	self:_check()
	if not self:visible() then return false end --false if hidden
	return self.backend:active()
end

function window:_backend_activated()
	self:_event'activated'
end

function window:_backend_deactivated()
	self:_event'deactivated'
end

--state/app visibility (OSX only) --------------------------------------------

function app:hidden()
	if not self.nw:os'OSX' then return false end
	return self.backend:hidden()
end

function app:unhide()
	if not self.nw:os'OSX' then return end
	return self.backend:unhide()
end

function app:hide()
	if not self.nw:os'OSX' then return end
	return self.backend:hide()
end

function app:_backend_did_unhide()
	self:_event'did_unhide'
end

function app:_backend_did_hide()
	self:_event'did_hide'
end

--state/visibility -----------------------------------------------------------

function window:visible()
	self:_check()
	return self.backend:visible()
end

function window:show()
	self:_check()
	self.backend:show()
end

function window:hide()
	self:_check()
	if self:fullscreen() then return end --ignore because OSX can't do it
	self.backend:hide()
end

--state/minimizing -----------------------------------------------------------

function window:minimized()
	self:_check()
	return self.backend:minimized()
end

function window:minimize()
	self:_check()
	if self:fullscreen() then return end --ignore because OSX can't do it
	self.backend:minimize()
end

--state/maximizing -----------------------------------------------------------

function window:maximized()
	self:_check()
	return self.backend:maximized()
end

function window:maximize()
	self:_check()
	if self:fullscreen() then return end --ignore because OSX can't do it
	self.backend:maximize()
end

--state/restoring ------------------------------------------------------------

function window:restore()
	self:_check()
	if self:fullscreen() then
		self:fullscreen(false)
	else
		self.backend:restore()
	end
end

function window:shownormal()
	self:_check()
	if self:fullscreen() then return end --ignore because OSX can't do it
	self.backend:shownormal()
end

--state/state changed ---------------------------------------------------------

function window:_backend_changed()
	self:_event'changed'
end

--state/fullscreen -----------------------------------------------------------

function window:fullscreen(fullscreen)
	self:_check()
	if fullscreen == nil then
		return self.backend:fullscreen()
	elseif fullscreen then
		if self:fullscreen() then return end --ignore null transition
		self.backend:enter_fullscreen()
	else
		if not self:fullscreen() then return end --ignore null transition
		self.backend:exit_fullscreen()
	end
end

--state/synthesis ------------------------------------------------------------

function window:state()
	return
		not self:visible() and 'hidden'
		or self:minimized() and 'minimized'
		or self:fullscreen() and 'fullscreen'
		or self:maximized() and 'maximized'
		or 'normal'
end

--positioning/conversions ----------------------------------------------------

local function point_or_rect(x, y, w, h)
	if not w and not h then
		return x, y
	else
		assert(w, 'width missing')
		assert(h, 'height missing')
		return x, y, w, h
	end
end

--point or rect in client space to screen space.
function window:to_screen(x, y, w, h)
	self:_check()
	x, y = self.backend:to_screen(x, y)
	return point_or_rect(x, y, w, h)
end

--point or rect in screen space to client space.
function window:to_client(x, y, w, h)
	self:_check()
	x, y = self.backend:to_client(x, y)
	return point_or_rect(x, y, w, h)
end

--frame rect for a frame type and client rectangle in screen coordinates.
function app:client_to_frame(frame, x, y, w, h)
	frame = checkframe(frame)
	return self.backend:client_to_frame(frame, x, y, w, h)
end

--client rect in screen coordinates for a frame type and frame rectangle.
function app:frame_to_client(frame, x, y, w, h)
	frame = checkframe(frame)
	local cx, cy, cw, ch = self.backend:frame_to_client(frame, x, y, w, h)
	cw = math.max(0, cw)
	ch = math.max(0, ch)
	return cx, cy, cw, ch
end

--positioning/rectangles -----------------------------------------------------

local function override_rect(x, y, w, h, x1, y1, w1, h1)
	return x1 or x, y1 or y, w1 or w, h1 or h
end

function window:frame_rect(x1, y1, w1, h1) --returns x, y, w, h
	self:_check()
	if x1 or y1 or w1 or h1 then
		if self:minimized() then
			self:normal_rect(x1, y1, w1, h1)
		end
		if self:fullscreen() then return end --ignore because OSX can't do it
		local x, y, w, h = self.backend:get_frame_rect()
		self.backend:set_frame_rect(override_rect(x, y, w, h, x1, y1, w1, h1))
	elseif self:minimized() then
		return self:normal_rect()
	else
		return self.backend:get_frame_rect()
	end
end

function window:normal_rect(x1, y1, w1, h1)
	self:_check()
	if x1 or y1 or w1 or h1 then
		if self:fullscreen() then return end --ignore because OSX can't do it
		local x, y, w, h = self.backend:get_normal_rect()
		self.backend:set_normal_rect(override_rect(x, y, w, h, x1, y1, w1, h1))
	else
		return self.backend:get_normal_rect()
	end
end

function window:client_rect(x1, y1, w1, h1)
	self:_check()
	if x1 or y1 or w1 or h1 then
		if self:fullscreen() then return end --ignore because OSX can't do it
		local cx, cy, cw, ch = self:client_rect()
		local cx, cy, cw, ch = override_rect(cx, cy, cw, ch, x1, y1, w1, h1)
		local x, y, w, h = self:frame_rect()
		local dx, dy = self:to_client(x, y)
		local ccw, cch = self:size()
		local dw, dh = w - ccw, h - cch
		self.backend:set_frame_rect(cx + dx, cy + dy, cw + dw, ch + dh)
	else
		return self:to_screen(0, 0, self:size())
	end
end

function window:size() --returns w, h
	self:_check()
	if self:minimized() then
		return 0, 0
	end
	return self.backend:get_size()
end

--positioning/constraints ----------------------------------------------------

function window:minsize(w, h)
	if not w and not h then
		return self.backend:get_minsize()
	else
		local maxw, maxh = self:maxsize()
		if w and maxw then w = math.min(w, maxw) end --avoid undefined behavior
		if h and maxh then h = math.min(h, maxh) end
		self.backend:set_minsize(w, h)
	end
end

function window:maxsize(w, h)
	if not w and not h then
		return self.backend:get_maxsize()
	else
		local minw, minh = self:minsize()
		if w and minw then w = math.max(w, minw) end --avoid undefined behavior
		if h and minh then h = math.max(h, minh) end
		self.backend:set_maxsize(w, h)
	end
end

--positioning/resizing -------------------------------------------------------

function window:_backend_start_resize(how)
	self._magnets = nil
	self:_event('start_resize', how)
end

function window:_backend_end_resize(how)
	self._magnets = nil
	self:_event('end_resize', how)
end

function window:_getmagnets()
	local mode = self:edgesnapping()
	local t
	if mode:find'app' then
		if mode:find'other' then
			t = self.backend:magnets() --app + other
		else
			t = {}
			for i,win in ipairs(self.app:windows()) do
				if win ~= self then
					local x, y, w, h = win:frame_rect()
					if x then
						t[#t+1] = {x = x, y = y, w = w, h = h}
					end
				end
			end
		end
	elseif mode:find'other' then
		error'NYI' --TODO
	end
	if mode:find'screen' then
		t = t or {}
		for i,disp in ipairs(self.app:displays()) do
			local x, y, w, h = disp:client_rect()
			t[#t+1] = {x = x, y = y, w = w, h = h}
			local x, y, w, h = disp:rect()
			t[#t+1] = {x = x, y = y, w = w, h = h}
		end
	end
	return t
end

function window:_backend_resizing(how, x, y, w, h)
	local x1, y1, w1, h1

	if self:edgesnapping() then
		self._magnets = self._magnets or self:_getmagnets()
		if how == 'move' then
			x1, y1 = box2d.snap_pos(20, x, y, w, h, self._magnets, true)
		else
			x1, y1, w1, h1 = box2d.snap_edges(20, x, y, w, h, self._magnets, true)
		end
		x1, y1, w1, h1 = override_rect(x, y, w, h, x1, y1, w1, h1)
	else
		x1, y1, w1, h1 = x, y, w, h
	end

	x1, y1, w1, h1 = override_rect(x1, y1, w1, h1, self:_handle('resizing', how, x1, y1, w1, h1))
	self:_fire('resizing', how, x, y, w, h, x1, y1, w1, h1)
	return x1, y1, w1, h1
end

function window:_backend_resized(how)
	self:_event('resized', how)
end

function window:edgesnapping(snapping)
	self:_check()
	if snapping == nil then
		return self._edgesnapping
	else
		if snapping == true then
			snapping = 'screen'
		end
		if self._edgesnapping ~= snapping then
			self._magnets = nil
			self._edgesnapping = snapping
			if self.backend.set_edgesnapping then
				self.backend:set_edgesnapping(snapping)
			end
		end
	end
end

--z-order --------------------------------------------------------------------

window:_property'topmost'

function window:zorder(zorder, relto)
	self:_check()
	if relto then
		relto:_check()
	end
	self.backend:set_zorder(zorder, relto)
end

--titlebar -------------------------------------------------------------------

window:_property'title'

--displays -------------------------------------------------------------------

local display = {}

function app:_display(backend)
	return glue.inherit(backend, display)
end

function display:rect()
	return self.x, self.y, self.w, self.h
end

function display:client_rect()
	return self.client_x, self.client_y, self.client_w, self.client_h
end

function app:displays()
	return self.backend:displays()
end

function app:display_count()
	return self.backend:display_count()
end

--the display containing the window with the keyboard focus.
function app:active_display()
	return self.backend:active_display()
end

function app:_backend_displays_changed()
	self:_event'displays_changed'
end

function window:display()
	self:_check()
	return self.backend:display()
end

--cursors --------------------------------------------------------------------

function window:cursor(name)
	return self.backend:cursor(name)
end

--frame ----------------------------------------------------------------------

function window:frame() self:_check(); return self._frame end
function window:minimizable() self:_check(); return self._minimizable end
function window:maximizable() self:_check(); return self._maximizable end
function window:closeable() self:_check(); return self._closeable end
function window:resizeable() self:_check(); return self._resizeable end
function window:fullscreenable() self:_check(); return self._fullscreenable end

function window:autoquit(autoquit)
	self:_check()
	if autoquit == nil then
		return self._autoquit
	else
		self._autoquit = autoquit
	end
end

--parent ---------------------------------------------------------------------

function window:parent()
	self:_check()
	return self._parent
end

--keyboard -------------------------------------------------------------------

function app:ignore_numlock(ignore)
	if ignore == nil then
		return self._ignore_numlock
	else
		self._ignore_numlock = ignore
	end
end

--merge virtual key names into ambiguous key names.
local common_keynames = {
	lshift          = 'shift',      rshift        = 'shift',
	lctrl           = 'ctrl',       rctrl         = 'ctrl',
	lalt            = 'alt',        ralt          = 'alt',
	lcommand        = 'command',    rcommand      = 'command',

	['left!']       = 'left',       numleft       = 'left',
	['up!']         = 'up',         numup         = 'up',
	['right!']      = 'right',      numright      = 'right',
	['down!']       = 'down',       numdown       = 'down',
	['pageup!']     = 'pageup',     numpageup     = 'pageup',
	['pagedown!']   = 'pagedown',   numpagedown   = 'pagedown',
	['end!']        = 'end',        numend        = 'end',
	['home!']       = 'home',       numhome       = 'home',
	['insert!']     = 'insert',     numinsert     = 'insert',
	['delete!']     = 'delete',     numdelete     = 'delete',
	['enter!']      = 'enter',      numenter      = 'enter',
}

local function translate_key(vkey)
	return common_keynames[vkey] or vkey, vkey
end

function window:_backend_keydown(key)
	self:_event('keydown', translate_key(key))
end

function window:_backend_keypress(key)
	self:_event('keypress', translate_key(key))
end

function window:_backend_keyup(key)
	self:_event('keyup', translate_key(key))
end

function window:_backend_keychar(char)
	self:_event('keychar', char)
end

function window:key(keys)
	self:_check()
	keys = keys:lower()
	if keys:find'[^%+]%+' then --'alt+f3' -> 'alt f3'; 'ctrl++' -> 'ctrl +'
		keys = keys:gsub('([^%+%s])%+', '%1 ')
	end
	if keys:find(' ', 1, true) then --it's a sequence, eg. 'alt f3'
		local found
		for key in keys:gmatch'[^%s]+' do
			if not self.backend:key(key) then
				return false
			end
			found = true
		end
		return assert(found, 'invalid key sequence')
	end
	return self.backend:key(keys)
end

--mouse ----------------------------------------------------------------------

function window:mouse(var)
	--hidden or minimized windows don't have a mouse state.
	if not self:visible() or self:minimized() then return nil end
	if var then
		return self._mouse[var]
	else
		return self._mouse
	end
end

function window:_backend_mousedown(button, mx, my)
	local t = self._down[button]
	if not t then
		t = {count = 0}
		self._down[button] = t
	end

	if t.count > 0
		and self.app:timediff(t.time) < t.interval
		and box2d.hit(mx, my, t.x, t.y, t.w, t.h)
	then
		t.count = t.count + 1
		t.time = self.app:time()
	else
		t.count = 1
		t.time = self.app:time()
		t.interval = self.app.backend:double_click_time()
		t.w, t.h = self.app.backend:double_click_target_area()
		t.x = mx - t.w / 2
		t.y = my - t.h / 2
	end

	self:_event('mousedown', button, mx, my)

	local reset = false
	if self.click then
		reset = self:click(button, t.count)
	end
	self:_fire('click', button, t.count, reset)
	if reset then
		t.count = 0
	end
end

function window:_backend_mouseup(button, x, y)
	self:_event('mouseup', button, x, y)
end

function window:_backend_mouseenter()
	self:_event'mouseenter'
end

function window:_backend_mouseleave()
	self:_event'mouseleave'
end

function window:_backend_mousemove(x, y)
	self:_event('mousemove', x, y)
end

function window:_backend_mousewheel(delta, x, y)
	self:_event('mousewheel', delta, x, y)
end

function window:_backend_mousehwheel(delta, x, y)
	self:_event('mousehwheel', delta, x, y)
end

--rendering ------------------------------------------------------------------

function window:bitmap()
	self:_check()
	return self.backend:bitmap()
end

function window:invalidate()
	self:_check()
	return self.backend:invalidate()
end

function window:_backend_repaint()
	self:_event'repaint'
end

function window:_backend_free_bitmap(bitmap)
	self:_event('free_bitmap', bitmap)
end

--views ----------------------------------------------------------------------

local view = glue.update({}, object)

function window:views()
	return glue.extend({}, self._views) --take a snapshot; back-to-front order
end

function window:view_count()
	return #self._views
end

function view:_new(window, backend_class, t)
	local self = glue.inherit({
		window = window,
		app = window.app,
	}, self)
	self.backend = backend_class:new(window.backend, self, t)
	table.insert(window._views, self)
	return self
end

function window:_free_views()
	while #self._views > 0 do
		self._views[#self._views]:free()
	end
end

function view:free()
	if self._dead then return end
	self:_event'freeing'
	self.backend:free()
	self._dead = true
	table.remove(self.window._views, indexof(self, self.window._views))
end

function view:_backend_render(...)
	self:_event('render', ...)
end

function view:invalidate()
	self:_check()
	self.backend:invalidate()
end

function app:invalidate()
	for i,win in ipairs(self:windows()) do
		if not win:dead() then
			win:invalidate()
		end
	end
end

function view:rect()
	return self.backend:rect()
end

function view:zorder(zorder, relto)
	if zorder == nil then
		return indexof(self, self.window._views)
	else
		if zorder == 'front' then
			--TODO
		elseif zorder == 'back' then
			--TODO
		else --number
			zorder = math.min(math.max(zorder, 1), self.window:view_count())
		end
		self.backend:set_zorder(zorder)
	end
end

local glview = glue.inherit({}, view)

function window:glview(t)
	return glview:_new(self, self.backend.glview, t)
end

--menus ----------------------------------------------------------------------

local menu = glue.update({}, object)

function wrap_menu(backend, menutype)
	if backend.frontend then
		return backend.frontend --already wrapped
	end
	local self = glue.inherit({backend = backend, menutype = menutype}, menu)
	backend.frontend = self
	return self
end

function app:menu(menu)
	return wrap_menu(self.backend:menu(), 'menu')
end

function app:menubar()
	return wrap_menu(self.backend:menubar(), 'menubar')
end

function window:menubar()
	return wrap_menu(self.backend:menubar(), 'menubar')
end

function window:popup(menu, x, y)
	return self.backend:popup(menu, x or 0, y or 0)
end

function menu:popup(win, x, y)
	win:popup(self, x, y)
end

function menu:_parseargs(index, text, action, options)
	local args = {}

	--args can have the form:
	--		([index, ]text, [action], [options])
	--		{index=, text=, action=, optionX=...}
	if type(index) == 'table' then
		args = index
		index = args.index
	elseif type(index) ~= 'number' then
		index, args.text, args.action, options = nil, index, text, action --index is optional
	else
		args.text, args.action = text, action
	end

	--default text is empty, i.e. separator.
	args.text = args.text or ''

	--action can be a function or a submenu.
	if type(args.action) == 'table' and args.action.menutype then
		args.action, args.submenu = nil, args.action
	end

	--options add to the sequential args but don't override them.
	glue.merge(args, options)

	--a title made of zero or more '-' means separator (not for menu bars).
	if self.menutype ~= 'menubar' and args.text:find'^%-*$' then
		args.separator = true
		args.text = ''
		args.action = nil
		args.submenu = nil
		args.enabled = true
		args.checked = false
	else
		if args.enabled == nil then args.enabled = true end
		if args.checked == nil then args.checked = false end
	end

	--the title can be followed by two or more spaces and then by a shortcut.
	local shortcut = args.text:reverse():match'^%s*(.-)%s%s'
	if shortcut then
		args.shortcut = shortcut:reverse()
		args.text = text
	end

	return index, args
end

function menu:add(...)
	return self.backend:add(self:_parseargs(...))
end

function menu:set(...)
	self.backend:set(self:_parseargs(...))
end

function menu:remove(index)
	self.backend:remove(index)
end

function menu:get(index, var)
	if var then
		local item = self.backend:get(index)
		return item and item[var]
	else
		return self.backend:get(index)
	end
end

function menu:item_count()
	return self.backend:item_count()
end

function menu:items(var)
	local t = {}
	for i = 1, self:item_count() do
		t[i] = self:get(i, var)
	end
	return t
end

function menu:checked(i, checked)
	if checked == nil then
		return self.backend:get_checked(i)
	else
		self.backend:set_checked(i, checked)
	end
end

function menu:enabled(i, enabled)
	if enabled == nil then
		return self.backend:get_enabled(i)
	else
		self.backend:set_enabled(i, enabled)
	end
end

--notification icons ---------------------------------------------------------

local notifyicon = glue.update({}, object)

function app:notifyicon(opt)
	local icon = notifyicon:_new(self, self.backend.notifyicon, opt)
	table.insert(self._notifyicons, icon)
	return icon
end

function notifyicon:_new(app, backend_class, opt)
	self = glue.inherit({app = app}, self)
	self.backend = backend_class:new(app.backend, self, opt)
	return self
end

function notifyicon:free()
	if self._dead then return end
	self.backend:free()
	self._dead = true
	table.remove(self.app._notifyicons, indexof(self, self.app._notifyicons))
end

function app:_free_notifyicons() --called on app:quit()
	while #self._notifyicons > 0 do
		self._notifyicons[#self._notifyicons]:free()
	end
end

function app:notifyicon_count()
	return #self._notifyicons
end

function app:notifyicons()
	return glue.extend({}, self._notifyicons) --take a snapshot
end

function notifyicon:bitmap()
	self:_check()
	return self.backend:bitmap()
end

function notifyicon:invalidate()
	return self.backend:invalidate()
end

function notifyicon:_backend_repaint()
	self:_event'repaint'
end

function notifyicon:_backend_free_bitmap(bitmap)
	self:_event('free_bitmap', bitmap)
end

function window:rect()
	self:_check()
	return self.backend:rect()
end

notifyicon:_property'tooltip'
notifyicon:_property'menu'
notifyicon:_property'text' --OSX only
notifyicon:_property'length' --OSX only

--window icon ----------------------------------------------------------------

local winicon = glue.update({}, object)

local function whicharg(which)
	assert(which == nil or which == 'small' or which == 'big')
	return which == 'small' and 'small' or 'big'
end

function window:icon(which)
	local which = whicharg(which)
	self._icons = self._icons or {}
	if not self._icons[which] then
		self._icons[which] = winicon:_new(self, which)
	end
	return self._icons[which]
end

function winicon:_new(window, which)
	self = glue.inherit({}, winicon)
	self.window = window
	self.which = which
	return self
end

function winicon:bitmap()
	return self.window.backend:icon_bitmap(self.which)
end

function winicon:invalidate()
	return self.window.backend:invalidate_icon(self.which)
end

function window:_backend_repaint_icon(which)
	which = whicharg(which)
	self._icons[which]:_event('repaint')
end

--dock icon ------------------------------------------------------------------

local dockicon = glue.update({}, object)

function app:dockicon()
	if not self._dockicon then
		self._dockicon = dockicon:_new(self)
	end
	return self._dockicon
end

function dockicon:_new(app)
	return glue.inherit({app = app}, self)
end

function dockicon:bitmap()
	return self.app.backend:dockicon_bitmap()
end

function dockicon:invalidate()
	self.app.backend:dockicon_invalidate()
end

function app:_free_dockicon()
	if not self.backend.dockicon_free then return end --only on OSX
	self.backend:dockicon_free()
end

function app:_backend_dockicon_repaint()
	self._dockicon:_event'repaint'
end

function app:_backend_dockicon_free_bitmap(bitmap)
	self._dockicon:_event('free_bitmap', bitmap)
end

--file chooser ---------------------------------------------------------------

--TODO: make default filetypes = {'*'} and add '*' filetype to indicate "all others".

local defaults = {
	title = nil,
	filetypes = nil, --{'png', 'txt', ...}; first is default
	multiselect = false,
}

function app:opendialog(opt)
	opt = glue.update({}, defaults, opt)
	assert(not opt.filetypes or #opt.filetypes > 0, 'filetypes cannot be an empty list')
	local paths = self.backend:opendialog(opt)
	if not paths then return nil end
	return opt.multiselect and paths or paths[1]
end

local defaults = {
	title = nil,
	filetypes = nil, --{'png', 'txt', ...}; first is default
	filename = nil,
	path = nil,
}

function app:savedialog(opt)
	opt = glue.update({}, defaults, opt)
	assert(not opt.filetypes or #opt.filetypes > 0, 'filetypes cannot be an empty list')
	return self.backend:savedialog(opt)
end

--clipboard ------------------------------------------------------------------

function app:clipboard(format)
	if not format then
		return self.backend:clipboard_formats()
	else
		return self.backend:get_clipboard(format)
	end
end

function app:setclipboard(data, format)
	local t
	if data == false then --clear clipboard
		assert(format == nil)
	elseif format == 'text' or (format == nil and type(data) == 'string') then
		t = {{format = 'text', data = data}}
	elseif format == 'files' and type(data) == 'table' then
		t = {{format = 'files', data = data}}
	elseif format == 'bitmap' or (format == nil and type(data) == 'table' and data.stride) then
		t = {{format = 'bitmap', data = data}}
	elseif format == nil and type(data) == 'table' and not data.stride then
		t = data
	else
		error'invalid argument'
	end
	return self.backend:set_clipboard(t)
end

--buttons --------------------------------------------------------------------

local button = glue.update({}, object)

function window:button(...)
	return button:_new(self, self.backend.button, ...)
end

function button:_new(window, backend_class, ...)
	self = glue.inherit({window = window}, self)
	self.backend = backend_class:new(...)
	return self
end

if not ... then require'nw_test' end

return nw
