// Created By: NeroMorte - main-thread nonblocking UDP discovery with bounded lifetime/results.
#pragma once
#include "TriuneEQBCProtocol.h"
#include <iphlpapi.h>
#pragma comment(lib,"iphlpapi.lib")
namespace triune_eqbc {
class Discovery {
 SOCKET socket_=INVALID_SOCKET;
 bool winsock_=false;
 uint64_t until_=0, expire_=0;
 unsigned counter_=0;
 std::string nonce_;
 std::vector<std::string> localAddresses_;
public:
 std::vector<Server> servers;
 std::string localIPs, error;
 ~Discovery(){ Close(); }
 void Close(){ if(socket_!=INVALID_SOCKET){closesocket(socket_);socket_=INVALID_SOCKET;} if(winsock_){WSACleanup();winsock_=false;} until_=0; }
 bool Scanning() const { return socket_!=INVALID_SOCKET; }
 void Start() {
  Close(); servers.clear(); error.clear(); localIPs.clear(); localAddresses_.clear();
  WSADATA data{};
  if(WSAStartup(MAKEWORD(2,2),&data)!=0){error="Windows sockets unavailable";return;}
  winsock_=true;
  socket_=::socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);
  if(socket_==INVALID_SOCKET){error="Discovery socket unavailable";Close();return;}
  u_long nonblocking=1;
  BOOL broadcast=TRUE;
  sockaddr_in bindTo{}; bindTo.sin_family=AF_INET; bindTo.sin_addr.s_addr=INADDR_ANY;
  if(ioctlsocket(socket_,FIONBIO,&nonblocking)!=0 || setsockopt(socket_,SOL_SOCKET,SO_BROADCAST,reinterpret_cast<const char*>(&broadcast),sizeof(broadcast))!=0 || bind(socket_,reinterpret_cast<sockaddr*>(&bindTo),sizeof(bindTo))!=0){error="Cannot open LAN discovery socket";Close();return;}
  char nonce[33]{};
  sprintf_s(nonce,"%llx%lx%x",static_cast<unsigned long long>(GetTickCount64()),static_cast<unsigned long>(GetCurrentProcessId()),++counter_);
  nonce_=nonce;
  std::string query="TRIUNE_EQBC_DISCOVER_V1 "+nonce_;
  auto sendQuery=[&](unsigned long ip){sockaddr_in to{};to.sin_family=AF_INET;to.sin_port=htons(DiscoveryPort);to.sin_addr.s_addr=ip;sendto(socket_,query.c_str(),static_cast<int>(query.size()),0,reinterpret_cast<sockaddr*>(&to),sizeof(to));};
  sendQuery(inet_addr("127.0.0.1")); sendQuery(INADDR_BROADCAST);
  ULONG size=0;
  if(GetAdaptersInfo(nullptr,&size)==ERROR_BUFFER_OVERFLOW && size<=1024*1024){
   std::vector<unsigned char> memory(size);
   auto first=reinterpret_cast<IP_ADAPTER_INFO*>(memory.data());
   if(GetAdaptersInfo(first,&size)==ERROR_SUCCESS) for(auto adapter=first;adapter;adapter=adapter->Next){
    for(auto ip=&adapter->IpAddressList;ip;ip=ip->Next){
     unsigned long address=inet_addr(ip->IpAddress.String), mask=inet_addr(ip->IpMask.String);
     if(address==INADDR_NONE || address==INADDR_ANY || mask==INADDR_NONE) continue;
     if(!localIPs.empty()) localIPs+=", "; localIPs+=ip->IpAddress.String; localAddresses_.push_back(ip->IpAddress.String);
     sendQuery(address | ~mask);
    }
   }
  }
  until_=GetTickCount64()+4000; expire_=GetTickCount64()+15000;
 }
 void Pulse() {
  auto now=GetTickCount64();
  if(expire_ && now>expire_){servers.clear();expire_=0;}
  if(socket_==INVALID_SOCKET) return;
  // A noisy LAN cannot starve the game thread.
  for(int i=0;i<16;++i){
   char buffer[256]{};sockaddr_in from{};int length=sizeof(from);
   int n=recvfrom(socket_,buffer,sizeof(buffer),0,reinterpret_cast<sockaddr*>(&from),&length);
   if(n==SOCKET_ERROR){if(WSAGetLastError()!=WSAEWOULDBLOCK && WSAGetLastError()!=WSAECONNRESET) error="Discovery receive failed";break;}
   if(n<=0 || n>=static_cast<int>(sizeof(buffer)) || from.sin_family!=AF_INET) continue;
   Server server;
   if(!Reply(std::string(buffer,n),nonce_,server)) continue;
   server.host=inet_ntoa(from.sin_addr);
   bool duplicate=false;
   for(const auto& prior:servers) if(prior.host==server.host && prior.port==server.port) duplicate=true;
   // Loopback and LAN replies from this machine are one server; prefer loopback.
   bool local=std::find(localAddresses_.begin(),localAddresses_.end(),server.host)!=localAddresses_.end() || server.host=="127.0.0.1";
   for(auto& prior:servers) if(local && prior.port==server.port && (prior.host=="127.0.0.1" || std::find(localAddresses_.begin(),localAddresses_.end(),prior.host)!=localAddresses_.end())) { prior.host="127.0.0.1";duplicate=true; }
   if(!duplicate && servers.size()<32) servers.push_back(server);
  }
  if(now>=until_) Close();
 }
};
}
