# Created By: NeroMorte - Compile actual movement methods and result capture against MQ doubles.
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parent
source=(root/'source/MQ2Navigation.cpp').read_text()
def method(name):
    start=source.index('void MQ2NavigationPlugin::'+name) if name in ('Look','UpdateXYZMovement','Stop') else source.index('bool MQ2NavigationPlugin::'+name)
    opening=source.index('{',start);level=1;i=opening+1
    while level:
        level+=(source[i]=='{')-(source[i]=='}');i+=1
    return source[start:i]
# Fixture contains MQ/GLM doubles and behavioral assertions; methods always come from shipped source.
fixture=(root/'movement_fixture.cpp').read_text()
first=fixture.index('// GENERATED_METHODS')
last=fixture.index('void elapse(')
pre=fixture[:first].replace('bool m_xyzStallActive=false;', 'bool m_xyzStallArrivalAccepted=false;bool m_xyzStallActive=false;')
program=pre+'\n'.join(method(n) for n in ('Look','UpdateXYZMovement','HandleXYZStall','TryXYZMovement'))+'\n'+fixture[last:]
completion=r'''
#include <memory>
#include <string>
#include <cstdint>
#include <cassert>
#include <iostream>
#define SPDLOG_INFO(...) ((void)0)
enum class DestinationType {Spawn,Location};
struct Spawn{int SpawnID=84;};
struct Info{DestinationType type=DestinationType::Spawn;Spawn* pSpawn=nullptr;std::string tag="triune_chase_84_1";};
struct Path{std::shared_ptr<Info> info=std::make_shared<Info>();auto GetDestinationInfo(){return info;}};
namespace nav {enum class NavObserverEvent {NavCanceled,NavDestinationReached};}
struct Observer{nav::NavObserverEvent event;void DispatchObserverEvent(nav::NavObserverEvent e,void*){event=e;}} observer;
Observer* s_navAPIImpl=&observer;
constexpr int APPLY_TO_ALL=0;
void TrueMoveOff(int){}
class MQ2NavigationPlugin{public:
bool m_isActive=true,m_xyzStallArrivalAccepted=false,m_lastResultReached=false,m_lastResultXYZStallArrival=false;
uint32_t m_lastResultSerial=0;int m_lastResultTargetID=0;std::string m_lastResultTag;
std::shared_ptr<Path> m_activePath=std::make_shared<Path>();std::shared_ptr<int> m_currentCommandState=std::make_shared<int>();
void Stop(bool);void ResetPath(){m_activePath.reset();m_xyzStallArrivalAccepted=false;}
};
'''+method('Stop')+r'''
int main(){
Spawn spawn;MQ2NavigationPlugin n;n.m_activePath->info->pSpawn=&spawn;
n.m_xyzStallArrivalAccepted=true;n.Stop(true);
assert(n.m_lastResultReached&&n.m_lastResultXYZStallArrival&&n.m_lastResultSerial==1);
assert(n.m_lastResultTargetID==84&&n.m_lastResultTag=="triune_chase_84_1");
assert(!n.m_xyzStallArrivalAccepted&&!n.m_activePath);
n.Stop(false);assert(n.m_lastResultSerial==1&&n.m_lastResultXYZStallArrival);
n.m_isActive=true;n.m_activePath=std::make_shared<Path>();n.m_activePath->info->type=DestinationType::Location;
n.m_xyzStallArrivalAccepted=true;n.Stop(false);
assert(n.m_lastResultSerial==2&&!n.m_lastResultReached&&!n.m_lastResultXYZStallArrival&&n.m_lastResultTargetID==0);
n.m_isActive=true;n.m_lastResultSerial=UINT32_MAX;n.Stop(true);assert(n.m_lastResultSerial==1);
std::cout<<"PASS: owned result publication, cancellation, inactive-stop retention, reset and serial wrap\n";
}
'''
with tempfile.TemporaryDirectory() as tmp:
    for name,text in [('movement',program),('completion',completion)]:
        path=Path(tmp)/f'{name}.cpp';path.write_text(text);binary=Path(tmp)/name
        subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(path),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True)
