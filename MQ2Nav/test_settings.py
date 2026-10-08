# Created By: NeroMorte - Compile the actual settings and option parser with isolated MQ doubles.
from pathlib import Path
import re,subprocess,tempfile
root=Path(__file__).resolve().parent
settings=(root/'source/PluginSettings.cpp').read_text()
header=(root/'source/PluginSettings.h').read_text()
nav=(root/'source/MQ2Navigation.cpp').read_text()
def method(text,name):
 start=text.index(name); opening=text.index('{',start);level=1;i=opening+1
 while level:
  level+=(text[i]=='{')-(text[i]=='}');i+=1
 return text[start:i]
pre=r'''
#include <cmath>
#include <string>
#include <string_view>
#include <map>
#include <vector>
#include <sstream>
#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <cassert>
#include <iostream>
#include <memory>
#include <cstdint>
#define SPDLOG_INFO(...) ((void)0)
#define SPDLOG_DEBUG(...) ((void)0)
#define SPDLOG_ERROR(...) ((void)0)
#define MAX_STRING 2048
using CHAR=char;
namespace glm {struct vec3 {float x,y,z;vec3(float a=0,float b=0,float c=0):x(a),y(b),z(c){}};}
namespace fmt {std::string format(const char*,const std::string& name){return name;}}
std::map<std::string,std::string> ini;
const char* INIFileName="test.ini";
bool to_bool(std::string s){std::transform(s.begin(),s.end(),s.begin(),::tolower);if(s=="1"||s=="on"||s=="true")return true;if(s=="0"||s=="off"||s=="false")return false;throw std::invalid_argument("boolean");}
namespace mq {
bool GetPrivateProfileBool(const std::string&,const std::string& k,bool d,const char*){return ini.count(k)?to_bool(ini[k]):d;}
float GetPrivateProfileFloat(const std::string&,const std::string&,float d,const char*){return d;}
template<class T>T GetPrivateProfileValue(const std::string&,const std::string& k,T d,const char*){if(!ini.count(k))return d;std::istringstream in(ini[k]);T v;return (in>>v)?v:d;}
void WritePrivateProfileBool(const std::string&,const std::string& k,bool v,const char*){ini[k]=v?"1":"0";}
void WritePrivateProfileString(const std::string&,const std::string& k,const char* v,const char*){ini[k]=v;}
void WritePrivateProfileFloat(const std::string&,const std::string&,float,const char*){}
}
void GetArg(char* out,const char* input,int idx){std::istringstream in(input);std::string v;for(int i=0;i<idx;++i)if(!(in>>v)){v.clear();break;}std::strcpy(out,v.c_str());}
void WritePrivateProfileStringA(const char*,const char* k,const char* v,const char*){ini[k]=v;}
int GetPrivateProfileString(const char*,const char* k,const char*,char* out,size_t n,const char*){if(!ini.count(k))return 0;std::strncpy(out,ini[k].c_str(),n);return int(ini[k].size());}
namespace nav {struct NavigationLine{struct LineStyle{uint32_t borderColor=0,hiddenColor=0,visibleColor=0,linkColor=0;float opacity=0,hiddenOpacity=0,borderWidth=0,lineWidth=0;};};NavigationLine::LineStyle gNavigationLineStyle;}
'''
header=re.sub(r'^#(?:include|pragma).*\n','',header,flags=re.M)
settings=re.sub(r'^#include.*\n','',settings,flags=re.M)
parse=r'''
namespace spdlog {namespace level {enum level_enum{off,info};level_enum from_str(std::string){return info;}}}
namespace nav {enum class FacingType{Forward,Backward};}
using nav::FacingType;
struct NavigationOptions {int distance=0;bool lineOfSight=true,paused=false,track=true;FacingType facing=FacingType::Forward;spdlog::level::level_enum logLevel=spdlog::level::info;};
struct NavigationArguments {std::string tag;bool xyzSteering=false;};
struct DestinationInfo {bool valid=true,xyzSteering=false;NavigationOptions options;std::string tag;};
struct ScopedLogLevel {ScopedLogLevel(int,spdlog::level::level_enum){}};
int GetIntFromString(std::string s,int d){try{return std::stoi(s);}catch(...){return d;}}
template<size_t N>void strncpy_s(char (&out)[N],const char* s,size_t n){std::memcpy(out,s,std::min(n,N-1));out[std::min(n,N-1)]=0;}
class MQ2NavigationPlugin {int sink=0;int* m_chatSink=&sink;public:
 std::shared_ptr<DestinationInfo> ParseDestinationInternal(std::string_view,int&){return std::make_shared<DestinationInfo>();}
 std::shared_ptr<DestinationInfo> ParseDestination(std::string_view,spdlog::level::level_enum);
 void ParseOptions(std::string_view,int,NavigationOptions&,NavigationArguments*);
};
'''
main=r'''
int main(){
 assert(!nav::GetSettings().xyz_steering);
 assert(nav::GetSettings().xyz_stall_arrival&&nav::GetSettings().xyz_stall_seconds==5&&nav::GetSettings().xyz_stall_distance==5);
 nav::LoadSettings();assert(!nav::GetSettings().xyz_steering);
 nav::GetSettings().xyz_steering=true;nav::GetSettings().autobreak=true;nav::SaveSettings();assert(ini["XYZ"]=="1");
 nav::GetSettings()=nav::SettingsData{};nav::LoadSettings();assert(nav::GetSettings().xyz_steering&&nav::GetSettings().autobreak);
 MQ2NavigationPlugin navPlugin;
 auto current=navPlugin.ParseDestination("",spdlog::level::info);assert(current->xyzSteering);
 assert(!navPlugin.ParseDestination("xyz=off",spdlog::level::info)->xyzSteering);
 assert(navPlugin.ParseDestination("dist=2 xyz=on",spdlog::level::info)->xyzSteering);
 assert(navPlugin.ParseDestination("spawn Mortefreddo | xyz=on dist=2",spdlog::level::info)->options.distance==2);
 assert(nav::ParseIniCommand("XYZ 0"));assert(!nav::GetSettings().xyz_steering);assert(ini["XYZ"]=="0");
 assert(!navPlugin.ParseDestination("",spdlog::level::info)->xyzSteering);
 assert(navPlugin.ParseDestination("xyz=on",spdlog::level::info)->xyzSteering);
 assert(current->xyzSteering); // Changing the default does not mutate an existing route.
 assert(nav::GetSettings().autobreak); // Changing XYZ preserves other saved settings.
 assert(nav::ParseIniCommand("XYZ 1"));assert(nav::GetSettings().xyz_steering);
 nav::GetSettings().xyz_steering=false;nav::SaveSettings();nav::GetSettings().xyz_steering=true;nav::LoadSettings();assert(!nav::GetSettings().xyz_steering);
 assert(nav::ParseIniCommand("XYZStallSeconds 500"));assert(nav::GetSettings().xyz_stall_seconds==30);
 assert(nav::ParseIniCommand("XYZStallSeconds -2"));assert(nav::GetSettings().xyz_stall_seconds==1);
 assert(nav::ParseIniCommand("XYZStallDistance 50"));assert(nav::GetSettings().xyz_stall_distance==25);
 assert(nav::ParseIniCommand("XYZStallDistance -1"));assert(nav::GetSettings().xyz_stall_distance==1);
 assert(nav::ParseIniCommand("XYZStallArrival 0"));assert(!nav::GetSettings().xyz_stall_arrival);
 nav::GetSettings().xyz_stall_distance=6;nav::GetSettings().xyz_stall_seconds=7;nav::SaveSettings();nav::GetSettings()=nav::SettingsData{};nav::LoadSettings();assert(!nav::GetSettings().xyz_stall_arrival&&nav::GetSettings().xyz_stall_seconds==7&&nav::GetSettings().xyz_stall_distance==6);
 std::cout<<"PASS: default off, persisted UI-style changes, reload, native ini command, route overrides and active route isolation\n";
}
'''
code=pre+header+settings+parse+method(nav,'std::shared_ptr<DestinationInfo> MQ2NavigationPlugin::ParseDestination(')+method(nav,'void MQ2NavigationPlugin::ParseOptions(')+main
with tempfile.TemporaryDirectory() as folder:
 p=Path(folder);(p/'test.cpp').write_text(code)
 subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(p/'test.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
for name in ('void MQ2NavigationPlugin::Look(', 'void MQ2NavigationPlugin::UpdateXYZMovement('):
 a=method(nav,name);b=method((root/'baseline/MQ2Navigation.cpp').read_text(),name)
 # Comment wording changed to describe the setting; steering code must remain identical.
 strip=lambda x:re.sub(r'//[^\n]*','',x)
 assert strip(a)==strip(b),name
print('PASS: tested pitch and braking formulas unchanged')
