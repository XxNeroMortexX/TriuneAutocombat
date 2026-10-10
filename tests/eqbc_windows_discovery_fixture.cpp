// Created By: NeroMorte - compile and exercise the exact Windows discovery socket code.
#include <winsock2.h>
#include <windows.h>
#include <vector>
#include <cstdio>
#include <cstring>
#include "../MQ2EQBC/source/TriuneEQBCDiscovery.h"
#include <cassert>
int main(){
 triune_eqbc::Discovery discovery;
 discovery.Start();
 auto until=GetTickCount64()+5000;
 while(discovery.Scanning() && GetTickCount64()<until){discovery.Pulse();Sleep(10);}
 assert(discovery.error.empty());
 bool found=false;
 for(const auto& server:discovery.servers) if(server.host=="127.0.0.1" && server.port==39113 && !server.password) found=true;
 assert(found);
 discovery.Close();
 assert(!discovery.Scanning());
 return 0;
}
