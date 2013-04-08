/*******************************************************************************
 * Copyright (c) 2012 Sierra Wireless and others.
 * All rights reserved. This program and the accompanying materials
 * are made available under the terms of the Eclipse Public License v1.0
 * which accompanies this distribution, and is available at
 * http://www.eclipse.org/legal/epl-v10.html
 *
 * Contributors:
 *     Fabien Fleutot for Sierra Wireless - initial API and implementation
 *******************************************************************************/

/* Wraps swi_statusname library, which converts between string and numeric
 * representations of status codes. */

#include <swi_statusname.h>
#include <lauxlib.h>

/* Converts a name into a numeric status, or `0` if unknown.
 * Warning: `0` also happens to be the status code corresponding to `"OK"`. */
static int api_name2num( lua_State *L) {
    const char *name = luaL_checkstring( L, 1);
    lua_pushinteger( L, swi_string2status( name));
    return 1;
}

/* Converts a numeric status into a name, or `nil` if not found. */
static int api_num2name( lua_State *L) {
    int num = luaL_checkinteger( L, 1);
    lua_pushstring( L, swi_status2string( num));
    return 1;
}

/* Loads the library. */
int luaopen_statusname( lua_State *L) {
    lua_newtable( L);
    lua_pushcfunction( L, api_name2num);
    lua_setfield( L, -2, "name2num");
    lua_pushcfunction( L, api_num2name);
    lua_setfield( L, -2, "num2name");
    return 1;
}
