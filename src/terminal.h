#pragma once

#include <stdio.h>

struct lua_State;
bool IsTerminal(FILE* file);
void RegisterTerminal(lua_State* L);
