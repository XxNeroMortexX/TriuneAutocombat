// Created By: NeroMorte - exercise the actual persisted MQ-root implementation.
#include "../MQ2WebUpdate/MQ2WebUpdateStagePlan.h"
#include <cassert>
#include <iostream>
int main() {
 using namespace mq2webupdate;
 using namespace profiles;
 assert(ParseDestinationRoot("mq") == DestinationRoot::MQ);
 assert(ResolveDestinationRoot("runtime",DestinationRoot::MQ) == "runtime");
 assert(IsSafeDeploymentPath(DestinationRoot::MQ,"EQBCS.exe"));
 for (const auto* bad : {"../EQBCS.exe","plugins/EQBCS.exe","webupdate_stage/plan","", "/EQBCS.exe"})
   assert(!IsSafeDeploymentPath(DestinationRoot::MQ,bad));
 Mapping m; m.id="server";m.name="server";m.remotePath="EQBCServers/EQBCS.exe";m.destinationRoot=DestinationRoot::MQ;m.recursive=false;
 assert(ValidateMapping(m).IsValid()); m.recursive=true;assert(!ValidateMapping(m).IsValid());
 m.recursive=false;m.destinationPath="plugins";assert(!ValidateMapping(m).IsValid());
 stageplan::Manifest source;source.profileId="morte";source.owner="XxNeroMortexX";source.repository="TriuneAutocombat";source.reference="main";source.commitSha=std::string(40,'a');
 planner::PlanItem item; item.mappingId="server";item.repositoryPath="EQBCServers/EQBCS.exe";item.stageRelativePath="server/EQBCS.exe";item.destinationRoot=DestinationRoot::MQ;item.destinationRelativePath="EQBCS.exe";item.expectedSize=300032;item.gitObjectSha=std::string(40,'b');source.items.push_back(item);
 stageplan::Manifest parsed;std::string error;
 assert(stageplan::Parse(stageplan::Serialize(source),parsed,error));assert(parsed.items[0].destinationRoot==DestinationRoot::MQ);
 source.items[0].destinationRelativePath="plugins/EQBCS.exe";assert(!stageplan::Parse(stageplan::Serialize(source),parsed,error));
 // Created By: NeroMorte - pair the source upgrade with the current profile serializer.
 Profile profile; profile.role=ProfileRole::MainDownload; profile.id="morte";profile.name="Morte";profile.owner="XxNeroMortexX";profile.repository="TriuneAutocombat";
 m.destinationPath.clear();profile.mappings.push_back(m);
 auto store=SerializeProfiles({profile});
 assert(store.find("Version=4\n")!=std::string::npos);
 std::vector<Profile> loaded;
 assert(ParseProfileStore(store,loaded,error));assert(loaded[0].mappings[0].destinationRoot==DestinationRoot::MQ);
 const auto version=store.find("Version=4");store.replace(version,9,"Version=3");
 assert(ParseProfileStore(store,loaded,error));
 std::cout << "MQ root and manifest tests passed\n";
}
