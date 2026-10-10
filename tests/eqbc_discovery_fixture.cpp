// Created By: NeroMorte - exercise the exact client protocol parser.
#include "../MQ2EQBC/source/TriuneEQBCProtocol.h"
#include <cassert>
#include <fstream>
#include <iterator>
int main(){
 // The reconnect toggle must be handled before the similarly named numeric interval.
 std::ifstream file("MQ2EQBC/source/MQ2EQBC.cpp");
 std::string source((std::istreambuf_iterator<char>(file)),std::istreambuf_iterator<char>());
 assert(source.find("!_stricmp(szArg, szSetAutoReconnect)") < source.find("!_strnicmp(szArg, szSetReconnect, sizeof(szSetReconnect))"));
 using namespace triune_eqbc;
 assert(InternalCommand("//ac net _eqbc abc123"));
 assert(InternalCommand(" /AC BOXNET _EQBC abc123 "));
 for(auto text:{"/echo /ac net _eqbc packet", "/ac net _eqbc", "/ac net _eqbcx packet", "/ac net _eqbc packet extra", "/ac net all /echo hi", "ordinary chat"}) assert(!InternalCommand(text));
 Server s;
 assert(Reply("TRIUNE_EQBC_SERVER_V1 abcd 4321 1","abcd",s));assert(s.port==4321 && s.password);
 for(auto text:{"TRIUNE_EQBC_SERVER_V1 other 2113 0","TRIUNE_EQBC_SERVER_V1 abcd 0 0","TRIUNE_EQBC_SERVER_V1 abcd 70000 0","TRIUNE_EQBC_SERVER_V1 abcd 2113 2","TRIUNE_EQBC_SERVER_V1 abcd 2113 0 extra"}) assert(!Reply(text,"abcd",s));
}
