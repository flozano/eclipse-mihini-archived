-------------------------------------------------------------------------------
-- The Debug Library.
-- This library provides the functionality of the debug interface to Lua programs.
-- You should exert care when using this library.
-- The functions provided here should be used exclusively for debugging and similar tasks,
-- such as profiling.
-- Please resist the temptation to use them as a usual programming tool:
-- they can be very slow. Moreover, several of these functions violate some assumptions
-- about Lua code (e.g., that variables local to a function cannot be accessed from outside
-- or that userdata metatables cannot be changed by Lua code) and therefore can compromise
-- otherwise secure code.
--
-- All functions in this library are provided inside the debug table.
-- All functions that operate over a thread have an optional first argument
-- which is the thread to operate over. The default is always the current thread.
-- @module debug

-------------------------------------------------------------------------------
-- Enters an interactive mode with the user, running each string that
-- the user enters. Using simple commands and other debug facilities,
-- the user can inspect global and local variables, change their values,
-- evaluate expressions, and so on. A line containing only the word `cont`
-- finishes this function, so that the caller continues its execution.
--
-- Note that commands for `debug.debug` are not lexically nested within any
-- function, and so have no direct access to local variables.
-- @function [parent=#debug] debug

-------------------------------------------------------------------------------
-- Returns the environment of object `o`.
-- @function [parent=#debug] getfenv
-- @param o object to handle.
-- @return #table the environment of object `o`.

-------------------------------------------------------------------------------
-- Returns the current hook settings of the thread, as three values: the
-- current hook function, the current hook mask, and the current hook count
-- (as set by the `debug.sethook` function).
-- @function [parent=#debug] gethook
-- @param #thread thread thread to handle.

-------------------------------------------------------------------------------
-- Returns a table with information about a function. You can give the
-- function directly, or you can give a number as the value of `func`,
-- which means the function running at level `func` of the call stack
-- of the given thread: level 0 is the current function (`getinfo` itself);
-- level 1 is the function that called `getinfo`; and so on. If `function`
-- is a number larger than the number of active functions, then `getinfo`
-- returns **nil**.
--
-- The returned table can contain all the fields returned by `lua_getinfo`,
-- with the string `what` describing which fields to fill in. The default for
-- `what` is to get all information available, except the table of valid
-- lines. If present, the option '`f`' adds a field named `func` with
-- the function itself. If present, the option '`L`' adds a field named
-- `activelines` with the table of valid lines.
--
-- For instance, the expression `debug.getinfo(1,"n").name` returns a table
-- with a name for the current function, if a reasonable name can be found,
-- and the expression `debug.getinfo(print)` returns a table with all available
-- information about the `print` function.
-- @function [parent=#debug] getinfo
-- @param #thread thread thread to handle.
-- @param func the function or a number which means the function running at level `func`.
-- @param #string what used to precise information returned.
-- @return #table with information about the function `func`.

-------------------------------------------------------------------------------
-- This function returns the name and the value of the local variable with
-- index `local` of the function at level `level` of the stack. (The first
-- parameter or local variable has index 1, and so on, until the last active
-- local variable.) The function returns nil if there is no local variable
-- with the given index, and raises an error when called with a `level` out
-- of range. (You can call `debug.getinfo` to check whether the level is valid.)
--
-- Variable names starting with '`(`' (open parentheses) represent internal
-- variables (loop control variables, temporaries, and C function locals).
-- @function [parent=#debug] getlocal
-- @param #thread thread thread which owns the local variable.
-- @param #number level the stack level.
-- @param #number local the index of the local variable.
-- @return The name and the value of the local variable with
-- index `local` of the function at level `level` of the stack.

-------------------------------------------------------------------------------
-- Returns the metatable of the given `object` or nil if it does not have
-- a metatable.
-- @function [parent=#debug] getmetatable
-- @param object object to handle.
-- @return #table the metatable of the given `object` or nil if it does not have
-- a metatable.

-------------------------------------------------------------------------------
-- Returns the registry table.
-- @function [parent=#debug] getregistry

-------------------------------------------------------------------------------
-- This function returns the name and the value of the upvalue with index
-- `up` of the function `func`. The function returns nil if there is no
-- upvalue with the given index.
-- @function [parent=#debug] getupvalue
-- @param func function which owns the upvalue.
-- @param #number up index of upvalue.
-- @return The name and the value of the upvalue with index
-- `up` of the function `func`.

-------------------------------------------------------------------------------
-- Sets the environment of the given `object` to the given `table`. Returns
-- `object`.
-- @function [parent=#debug] setfenv
-- @param object object to handle.
-- @param #table table the environment to set.
-- @return the given object.

-------------------------------------------------------------------------------
-- Sets the given function as a hook. The string `mask` and the number
-- `count` describe when the hook will be called. The string mask may have
-- the following characters, with the given meaning:
--
--   * `"c"`: the hook is called every time Lua calls a function;
--   * `"r"`: the hook is called every time Lua returns from a function;
--   * `"l"`: the hook is called every time Lua enters a new line of code.
--
-- With a `count` different from zero, the hook is called after every `count`
-- instructions.
--
-- When called without arguments, `debug.sethook` turns off the hook.
--
-- When the hook is called, its first parameter is a string describing
-- the event that has triggered its call: `"call"`, `"return"` (or `"tail
-- return"`, when simulating a return from a tail call), `"line"`, and
-- `"count"`. For line events, the hook also gets the new line number as its
-- second parameter. Inside a hook, you can call `getinfo` with level 2 to
-- get more information about the running function (level 0 is the `getinfo`
-- function, and level 1 is the hook function), unless the event is `"tail
-- return"`. In this case, Lua is only simulating the return, and a call to
-- `getinfo` will return invalid data.
-- @function [parent=#debug] sethook
-- @param #thread thread thread on which the hook is set.
-- @param hook a function which takes two argument : event as string and line number.
-- @param #string mask could be `"c"`, `"r"` or `"l"`.
-- @param #number count the hook is called after every `count` instructions.

-------------------------------------------------------------------------------
-- This function assigns the value `value` to the local variable with
-- index `local` of the function at level `level` of the stack. The function
-- returns nil if there is no local variable with the given index, and raises
-- an error when called with a `level` out of range. (You can call `getinfo`
-- to check whether the level is valid.) Otherwise, it returns the name of
-- the local variable.
-- @function [parent=#debug] setlocal
-- @param #thread thread thread which owns the local variable.
-- @param #number level the stack level.
-- @param #number local the index of the local variable.
-- @param value the new value.
-- @return #string the name of the variable if it succeed.
-- @return #nil if there no local variable with the given index.

-------------------------------------------------------------------------------
-- Sets the metatable for the given `object` to the given `table` (which
-- can be nil).
-- @function [parent=#debug] setmetatable
-- @param object object to handle.
-- @param #table table the metatable for `object`.

-------------------------------------------------------------------------------
-- This function assigns the value `value` to the upvalue with index `up`
-- of the function `func`. The function returns nil if there is no upvalue
-- with the given index. Otherwise, it returns the name of the upvalue.
-- @function [parent=#debug] setupvalue
-- @param func function which owns the upvalue.
-- @param up index of the upvalue.
-- @param value the new value.
-- @return #string the name of the upvalue if it succeed.
-- @return #nil if there no upvalue with the given index.

return nil
