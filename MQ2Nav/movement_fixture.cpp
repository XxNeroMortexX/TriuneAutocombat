// Created By: NeroMorte - Exercise the actual patched methods with isolated MQ/GLM test doubles.
#include <cmath>
#include <chrono>
#include <cassert>
#include <memory>
#include <iostream>
#define SPDLOG_WARN(...) ((void)0)
#define SPDLOG_INFO(...) ((void)0)
namespace nav {struct SettingsData{bool xyz_stall_arrival=true;int xyz_stall_seconds=5;float xyz_stall_distance=5;};SettingsData settings;SettingsData& GetSettings(){return settings;}}
namespace glm {
struct vec2 {float x,y; vec2(float a,float b):x(a),y(b){} };
struct vec3 {float x,y,z; vec3(float a=0,float b=0,float c=0):x(a),y(b),z(c){} };
float length(vec2 v){return std::sqrt(v.x*v.x+v.y*v.y);}
float distance2(vec3 a,vec3 b){return (a.x-b.x)*(a.x-b.x)+(a.y-b.y)*(a.y-b.y)+(a.z-b.z)*(a.z-b.z);}
float distance(vec3 a,vec3 b){return std::sqrt(distance2(a,b));}
float atan(float a,float b){return std::atan2(a,b);}
template<class T> T pi(){return static_cast<T>(3.14159265358979323846);}
}
enum class FacingType {Forward,Backward};
enum class DestinationType {Spawn,Location};
enum { GO_FORWARD,GO_BACKWARD };
int released=0; float velocity=0;
void TrueMoveOff(int){++released;}
float GetMyVelocity(){return velocity;}
struct Player {float X=0,Y=0,Z=0,Heading=0,CameraAngle=0,FloorHeight=0; int UnderWater=5,FeetWet=0; struct {int Levitate=0;} mPlayerPhysicsClient;};
Player me, leader; using PSPAWNINFO=Player*; Player* pControlledPlayer=&me;
struct CharInfo {Player* pSpawn=&me;} character;
CharInfo* GetCharInfo(){return &character;}
float gFaceAngle=0,gLookAngle=0; glm::vec3 s_lastFace;
bool actualLoS=true;
bool LineOfSight(Player*,Player*){return actualLoS;}
bool useFloorHeight=true;
glm::vec3 GetSpawnPosition(Player* p){return {p->X,p->Y,useFloorHeight ? p->FloorHeight : p->Z};}
glm::vec3 GetMyPosition(){return GetSpawnPosition(&me);}
struct Info {bool xyzSteering=true; DestinationType type=DestinationType::Spawn; Player* pSpawn=&leader; struct {bool track=true; int distance=1; FacingType facing=FacingType::Forward;} options; glm::vec3 eqDestinationPos;};
struct Path {std::shared_ptr<Info> info=std::make_shared<Info>(); bool meshLoS=true, atEnd=false; bool IsAtEnd(){return atEnd;} auto GetDestinationInfo(){return info;} bool CanSeeDestination(){return meshLoS;}};
struct State {glm::vec3 destination;};
class MQ2NavigationPlugin {public: bool m_isPaused=false; std::shared_ptr<Path> m_activePath=std::make_shared<Path>(); std::shared_ptr<State> m_currentCommandState=std::make_shared<State>(); int pressed=0,finished=0,cancelled=0; void Stop(bool){++cancelled;}
std::chrono::steady_clock::time_point m_xyzLookTimer{}; bool m_xyzLookActive=false; float m_xyzLookAngle=0;
std::chrono::steady_clock::time_point m_xyzMoveTimer{}; int m_xyzMovePhase=0;
bool m_xyzStallActive=false;std::chrono::steady_clock::time_point m_xyzProgressTimer{};float m_xyzBestDistance=0;glm::vec3 m_xyzProgressTarget{};
bool HandleXYZStall(const glm::vec3&,float,float,float,FacingType);
void UpdateXYZMovement(float,float,FacingType);
void Look(const glm::vec3&,FacingType,bool=false); bool TryXYZMovement();
void PressMovementKey(FacingType){++pressed;} void MovementFinished(const glm::vec3&,FacingType){++finished;}
};
// GENERATED_METHODS
void elapse(MQ2NavigationPlugin& n, int ms){n.m_xyzLookTimer=std::chrono::steady_clock::now()-std::chrono::milliseconds(ms);}
int main(){
 MQ2NavigationPlugin n;
 me.Z=-300; me.FloorHeight=-400; leader.Z=-7; leader.FloorHeight=-400;
 n.m_activePath->info->eqDestinationPos=GetSpawnPosition(&leader);
 assert(n.TryXYZMovement()); assert(n.finished==0); assert(std::abs(me.CameraAngle-128)<0.001);
 assert(n.m_activePath->info->eqDestinationPos.z==-400);
 leader.Z=-380; elapse(n,16); assert(n.TryXYZMovement());
 assert(me.CameraAngle<128 && me.CameraAngle>0); // reversal is filtered, not an instant flip
 for(int i=0;i<40;++i){elapse(n,16); n.TryXYZMovement();}
 assert(std::abs(me.CameraAngle+128)<0.1);
 leader.Z=-299.5; assert(n.TryXYZMovement()); assert(n.finished==1); // unchanged XYZ arrival
 assert(n.m_activePath->info->eqDestinationPos.z==-400);
 n.m_isPaused=true; const int moves=n.pressed; assert(n.TryXYZMovement()); assert(n.pressed==moves); n.m_isPaused=false;
 actualLoS=false; n.m_activePath->atEnd=true; assert(n.TryXYZMovement()); assert(n.cancelled==1); actualLoS=true; n.m_activePath->atEnd=false;
 n.m_activePath->info->xyzSteering=false; assert(!n.TryXYZMovement()); n.m_activePath->info->xyzSteering=true;
 n.m_activePath->info->options.track=false; assert(!n.TryXYZMovement()); n.m_activePath->info->options.track=true;
 me=Player{}; leader=Player{};
 n.Look({0,0,100},FacingType::Forward,false); assert(std::abs(me.CameraAngle-64)<0.001); assert(!n.m_xyzLookActive);
 n.Look({0,0,-100},FacingType::Forward,true); assert(std::abs(me.CameraAngle+128)<0.001);
 elapse(n,300); n.Look({0,0,100},FacingType::Forward,true); assert(std::abs(me.CameraAngle-128)<0.001); // no stale smoothing after a long gap
 n.m_xyzLookActive=false; n.Look({100,0,-100},FacingType::Backward,true); assert(std::abs(me.CameraAngle-64)<0.001);
 me.UnderWater=0; me.mPlayerPhysicsClient.Levitate=2; n.m_xyzLookActive=false;
 n.Look({0,0,100},FacingType::Forward,true); assert(std::abs(me.CameraAngle-128)<0.001);
 n.Look({0,0,100},FacingType::Forward,false); assert(me.CameraAngle==45 && !n.m_xyzLookActive); // original lev behavior
 me=Player{};
 MQ2NavigationPlugin far,near;
 far.Look({0,0,-100},FacingType::Forward,true); near.Look({0,0,-3},FacingType::Forward,true);
 elapse(far,16); far.Look({0,0,100},FacingType::Forward,true); const float farAngle=me.CameraAngle;
 elapse(near,16); near.Look({0,0,3},FacingType::Forward,true); assert(me.CameraAngle>farAngle); // faster near arrival
 MQ2NavigationPlugin fpsA,fpsB;
 fpsA.Look({0,0,-100},FacingType::Forward,true); fpsB.Look({0,0,-100},FacingType::Forward,true);
 for(int i=0;i<8;++i){elapse(fpsA,10); fpsA.Look({0,0,100},FacingType::Forward,true);}
 const float angleA=me.CameraAngle;
 for(int i=0;i<4;++i){elapse(fpsB,20); fpsB.Look({0,0,100},FacingType::Forward,true);}
 assert(std::abs(angleA-me.CameraAngle)<0.1); // response depends on time rather than number of pulses
 // Precision thrust must release before tapping, without reporting arrival.
 me=Player{}; leader=Player{}; leader.Y=1.8f; velocity=25;
 MQ2NavigationPlugin brake; released=0;
 assert(brake.TryXYZMovement()); assert(brake.pressed==0 && released==2 && brake.finished==0);
 brake.m_xyzMoveTimer=std::chrono::steady_clock::now()-std::chrono::milliseconds(160);
 brake.TryXYZMovement(); assert(brake.pressed==0); // still coasting at speed
 velocity=0; brake.TryXYZMovement(); assert(brake.pressed==1 && brake.m_xyzMovePhase==1);
 brake.m_xyzMoveTimer=std::chrono::steady_clock::now()-std::chrono::milliseconds(60);
 brake.TryXYZMovement(); assert(brake.pressed==1 && brake.m_xyzMovePhase==2);
 leader.Y=30; brake.TryXYZMovement(); assert(brake.pressed==2 && brake.m_xyzMovePhase==0); // leader moves away: resume continuous thrust
 leader.Y=.9; brake.TryXYZMovement(); assert(brake.finished==1); // exact requested distance unchanged
 MQ2NavigationPlugin predictive; velocity=40; leader.Y=6;
 predictive.TryXYZMovement(); assert(predictive.pressed==0 && predictive.finished==0); // brake before overshooting
 predictive.m_xyzMoveTimer=std::chrono::steady_clock::now()-std::chrono::milliseconds(310);
 predictive.TryXYZMovement(); assert(predictive.pressed==1); // bounded coast cannot lock a route forever

 // New final-approach tests: actual timing, distance cap, progress and eligibility.
 me=Player{};me.UnderWater=0;me.mPlayerPhysicsClient.Levitate=2;leader=Player{};leader.X=.36f;leader.Z=4.05f;
 MQ2NavigationPlugin finish;finish.m_activePath->info->options.distance=2;
 assert(finish.TryXYZMovement());assert(finish.m_xyzStallActive&&finish.finished==0);
 finish.m_xyzProgressTimer=std::chrono::steady_clock::now()-std::chrono::milliseconds(4900);
 assert(finish.TryXYZMovement());assert(finish.finished==0);
 finish.m_xyzProgressTimer=std::chrono::steady_clock::now()-std::chrono::milliseconds(5100);
 assert(finish.TryXYZMovement());assert(finish.finished==1&&finish.cancelled==0&&!finish.m_xyzStallActive);
 MQ2NavigationPlugin outside;outside.m_activePath->info->options.distance=2;leader.Z=7;
 outside.TryXYZMovement();outside.m_xyzProgressTimer=std::chrono::steady_clock::now()-std::chrono::milliseconds(5100);
 outside.TryXYZMovement();assert(outside.finished==0&&outside.cancelled==1);
 MQ2NavigationPlugin cap;leader.X=0;leader.Z=5;cap.TryXYZMovement();cap.m_xyzProgressTimer=std::chrono::steady_clock::now()-std::chrono::milliseconds(5100);cap.TryXYZMovement();assert(cap.finished==1);
 MQ2NavigationPlugin farXY;leader.X=3;leader.Z=4;farXY.m_activePath->info->options.distance=2;
 farXY.m_xyzStallActive=true;farXY.m_xyzProgressTimer=std::chrono::steady_clock::now()-std::chrono::milliseconds(10000);
 farXY.TryXYZMovement();assert(!farXY.m_xyzStallActive&&farXY.finished==0&&farXY.cancelled==0);
 MQ2NavigationPlugin progress;leader.X=0;leader.Z=4.5f;progress.TryXYZMovement();progress.m_xyzProgressTimer=std::chrono::steady_clock::now()-std::chrono::milliseconds(5100);leader.Z=4.1f;
 progress.TryXYZMovement();assert(progress.finished==0&&progress.m_xyzBestDistance<4.2f);
 MQ2NavigationPlugin smallProgress;leader.Z=4.9f;smallProgress.TryXYZMovement();
 for(float z:{4.8f,4.7f,4.6f}){leader.Z=z;smallProgress.TryXYZMovement();}
 assert(smallProgress.m_xyzBestDistance<4.7f); // cumulative small steps count.
 MQ2NavigationPlugin moving;leader.Z=4.5f;moving.TryXYZMovement();moving.m_xyzProgressTimer=std::chrono::steady_clock::now()-std::chrono::milliseconds(5100);leader.Z=3.2f;
 moving.TryXYZMovement();assert(moving.finished==0&&moving.m_xyzProgressTarget.z==3.2f);
 MQ2NavigationPlugin off;leader.Z=4;nav::settings.xyz_stall_arrival=false;off.TryXYZMovement();assert(!off.m_xyzStallActive&&off.finished==0);nav::settings.xyz_stall_arrival=true;
 MQ2NavigationPlugin eligibility;eligibility.m_xyzStallActive=true;eligibility.m_activePath->info->xyzSteering=false;eligibility.TryXYZMovement();assert(!eligibility.m_xyzStallActive);
 eligibility.m_xyzStallActive=true;eligibility.m_activePath->info->xyzSteering=true;eligibility.m_isPaused=true;eligibility.TryXYZMovement();assert(!eligibility.m_xyzStallActive&&eligibility.finished==0);eligibility.m_isPaused=false;
 eligibility.m_xyzStallActive=true;actualLoS=false;eligibility.TryXYZMovement();assert(!eligibility.m_xyzStallActive&&eligibility.finished==0);actualLoS=true;
 eligibility.m_xyzStallActive=true;eligibility.m_activePath->meshLoS=false;eligibility.TryXYZMovement();assert(!eligibility.m_xyzStallActive&&eligibility.finished==0);eligibility.m_activePath->meshLoS=true;
 eligibility.m_xyzStallActive=true;eligibility.m_activePath->info->type=DestinationType::Location;eligibility.TryXYZMovement();assert(!eligibility.m_xyzStallActive);eligibility.m_activePath->info->type=DestinationType::Spawn;
 eligibility.m_xyzStallActive=true;me.mPlayerPhysicsClient.Levitate=0;eligibility.TryXYZMovement();assert(!eligibility.m_xyzStallActive);me.UnderWater=5;
 MQ2NavigationPlugin exact;leader.Z=.9f;exact.TryXYZMovement();assert(exact.finished==1&&!exact.m_xyzStallActive); // requested arrival still wins immediately.
 std::cout<<"PASS: stalled visible close arrival, cancellation outside cap, five-second window, progress, target movement, disable, pause, LOS, mesh visibility and spawn/XYZ/water gates.\n";
 std::cout<<"Passed: braking/taps/coast, live-target movement, exact arrival, plus actual XYZ vs floor anchors, arrival, moving target, pitch filter, elapsed-time response, near-target response, pause/LOS/track/opt-in gates, water/lev/backward, original look behavior.\n";
}
