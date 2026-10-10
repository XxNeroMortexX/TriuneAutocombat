// Created By: NeroMorte - shared bounded protocol parsing, without MacroQuest dependencies.
#pragma once
#include <string>
#include <sstream>
#include <algorithm>
#include <cctype>
namespace triune_eqbc {
constexpr unsigned short DiscoveryPort = 2114;
inline bool InternalCommand(const char* command) {
 if (!command) return false;
 std::istringstream stream(command);
 std::string root, net, frame, payload, extra;
 if (!(stream >> root >> net >> frame >> payload) || (stream >> extra)) return false;
 auto lower=[](std::string& s){ std::transform(s.begin(),s.end(),s.begin(),[](unsigned char c){return char(std::tolower(c));}); };
 lower(root); lower(net); lower(frame);
 return (root=="/ac" || root=="//ac") && (net=="net" || net=="boxnet") && frame=="_eqbc";
}
struct Server { std::string host; unsigned short port=0; bool password=false; };
inline bool Reply(const std::string& text,const std::string& nonce,Server& server) {
 std::istringstream stream(text);
 std::string magic, echo, extra;
 int port=0, protectedFlag=0;
 if (!(stream>>magic>>echo>>port>>protectedFlag) || (stream>>extra)) return false;
 if (magic!="TRIUNE_EQBC_SERVER_V1" || echo!=nonce || nonce.empty() || port<1 || port>65535 || (protectedFlag!=0 && protectedFlag!=1)) return false;
 server.port=static_cast<unsigned short>(port); server.password=protectedFlag!=0;
 return true;
}
}
