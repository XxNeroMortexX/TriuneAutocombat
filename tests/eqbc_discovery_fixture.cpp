// Created By: NeroMorte - exercise the exact client protocol parser.
#include "../MQ2EQBC/source/TriuneEQBCProtocol.h"
#include <cassert>
int main(){
 using namespace triune_eqbc;
 assert(InternalCommand("//ac net _eqbc abc123"));
 assert(InternalCommand(" /AC BOXNET _EQBC abc123 "));
 for(auto text:{"/echo /ac net _eqbc packet", "/ac net _eqbc", "/ac net _eqbcx packet", "/ac net _eqbc packet extra", "/ac net all /echo hi", "ordinary chat"}) assert(!InternalCommand(text));
 Server s;
 assert(Reply("TRIUNE_EQBC_SERVER_V1 abcd 4321 1","abcd",s));assert(s.port==4321 && s.password);
 for(auto text:{"TRIUNE_EQBC_SERVER_V1 other 2113 0","TRIUNE_EQBC_SERVER_V1 abcd 0 0","TRIUNE_EQBC_SERVER_V1 abcd 70000 0","TRIUNE_EQBC_SERVER_V1 abcd 2113 2","TRIUNE_EQBC_SERVER_V1 abcd 2113 0 extra"}) assert(!Reply(text,"abcd",s));
}
