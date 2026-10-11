#!/usr/bin/env python3
# Created By: NeroMorte - compile the shipped request coordinator with HTTP/Windows doubles.
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'MQ2WebUpdate/MQ2WebUpdate.cpp').read_text()
def function(signature):
    begin = source.index(signature)
    brace = source.index('{', begin)
    depth = 1
    end = brace + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    return source[begin:end]

begin = source.index('    struct CachedHttpResponse')
end = source.index('    std::string FormatGitHubResetTime', begin)
coordinator = source[begin:end].replace('std::time(nullptr)', 'fakeNow')
# Keep real SHA and line-ending code; only the OS/transport boundary is replaced.
sha = function('    std::string ComputeGitBlobSha(const std::string& bytes)\n    {')
normalize = function('    std::string NormalizeTextLineEndings(')
text_type = function('    bool IsTextDeployment(')
stage_begin = source.index('            // Edited By: NeroMorte - classify broken links')
stage_end = source.index('            const auto request = provider->FileRequest(', stage_begin)
stage_prefix = source[stage_begin:stage_end]
integrity_begin = source.index('            if (response.text.size() != remote.expectedSize ||')
integrity_end = source.index('\n            {', integrity_begin)
integrity = source[integrity_begin:integrity_end]
provider_code = r'''
#include "MQ2WebUpdate/MQ2WebUpdateProviders.h"
#include "MQ2WebUpdate/MQ2WebUpdateNetworkPolicy.h"
#include <openssl/sha.h>
#include <curl/curl.h>
#include <cassert>
#include <fstream>
#include <sstream>
#include <mutex>
#include <thread>
#include <chrono>
#include <map>
#include <deque>
#include <ctime>
#include <iostream>
namespace fs = std::filesystem;
std::int64_t fakeNow = 2000000000;
using HANDLE = void*;
using DWORD = unsigned long;
constexpr DWORD WAIT_OBJECT_0 = 0, WAIT_ABANDONED = 128;
constexpr bool FALSE = false;
bool mutexReady = true;
HANDLE CreateMutexA(void*, bool, const char*) { return reinterpret_cast<HANDLE>(1); }
DWORD WaitForSingleObject(HANDLE, int) { return mutexReady ? WAIT_OBJECT_0 : 258; }
void ReleaseMutex(HANDLE) {}
void CloseHandle(HANDLE) {}
namespace cpr {
using Header = std::map<std::string, std::string>;
struct Url { std::string value; };
struct Timeout { int value; };
struct Response { long status_code=0; std::string text; Header header; bool error=false; };
std::deque<Response> replies;
int calls = 0;
Header lastHeaders;
Response Get(const Url&, const Header& headers, const Timeout&) {
    ++calls; lastHeaders=headers; assert(!replies.empty());
    auto response=replies.front(); replies.pop_front(); return response;
}
}
fs::path runtime;
fs::path GetRuntimeLuaDirectory() { return runtime / "lua"; }
bool ReadFileBinary(const fs::path& path, std::string& out) {
    std::ifstream in(path, std::ios::binary); if (!in) return false;
    std::ostringstream bytes; bytes << in.rdbuf(); out=bytes.str(); return true;
}
bool WriteFileBinaryAtomic(const fs::path& path, const std::string& bytes) {
    std::ofstream out(path, std::ios::binary); out << bytes; return out.good();
}
std::mutex g_githubRequestMutex;
std::chrono::steady_clock::time_point g_lastGitHubRequest;
int g_networkRetryCount=2, g_networkTimeoutSeconds=15;
std::string ComputeGitBlobSha(const std::string&);
std::string ResponseHeaderValue(const cpr::Response&, const std::string&);
'''
tail = r'''
struct TestRemote { std::string gitObjectSha, destinationRelativePath, fileName; std::uint64_t expectedSize=0; };
struct TestResult { std::string status; };
struct TestOutput { int errorCount=0, sameCount=0; std::string lastError; std::vector<TestResult> fileResults; };
TestOutput StageDecision(const fs::path& localPath, const TestRemote& remote, bool localProtected, bool localExists) {
    TestOutput output;
    for (int one=0; one<1; ++one) {
        TestResult result;
STAGE_PREFIX
        result.status="DOWNLOAD";
        output.fileResults.push_back(result);
    }
    return output;
}
bool DownloadMatches(const cpr::Response& response, const TestRemote& remote) {
INTEGRITY
        return false;
    return true;
}
void queue(long status, const std::string& text="{}", cpr::Header headers={}) {
    cpr::replies.push_back({status, text, headers, false});
    g_lastGitHubRequest = {}; // No real pacing delay in the deterministic test.
}
void clearMemory() { g_httpMetadataCache.clear(); g_httpCooldowns.clear(); }
int main(int argc, char** argv) {
    assert(argc==2); runtime=argv[1]; fs::create_directories(runtime / "lua");
    const std::string sha(40,'a');
    const auto commit="https://api.github.com/repos/test/repo/commits/main";
    const auto tree="https://api.github.com/repos/test/repo/git/trees/" + sha + "?recursive=1";
    using namespace mq2webupdate::network;
    assert(MetadataCacheSeconds(tree, false)==86400);
    assert(MetadataCacheSeconds(commit, false)==30);
    assert(MetadataCacheSeconds(commit, true)==0);
    assert(!IsImmutableTreeUrl("https://api.github.com/repos/test/repo/git/trees/main?recursive=1"));
    assert(PositiveInteger("123junk")==0 && PositiveInteger("-2")==0);
    assert(PositiveInteger("99999999999999999999999")==0);
    assert(CooldownUntil(403,"0",std::to_string(fakeNow+3600),0,false,fakeNow)==fakeNow+3601);
    assert(CooldownUntil(429,"","",120,false,fakeNow)==fakeNow+121);
    assert(CooldownUntil(403,"","",0,false,fakeNow)==0);

    // Concurrent-entry/reload clients reuse one public reference and tree.
    queue(200,"commit-one"); assert(GitHubProviderGet(commit,"",false).text=="commit-one");
    const int first=cpr::calls;
    assert(GitHubProviderGet(commit,"",false).text=="commit-one" && cpr::calls==first);
    clearMemory();
    assert(GitHubProviderGet(commit,"",false).text=="commit-one" && cpr::calls==first);
    fakeNow += 31; queue(200,"commit-two");
    assert(GitHubProviderGet(commit,"",false).text=="commit-two" && cpr::calls==first+1);
    queue(200,"immutable-tree"); GitHubProviderGet(tree,"",false);
    const int treeCalls=cpr::calls; clearMemory(); fakeNow += 3600;
    assert(GitHubProviderGet(tree,"",false).text=="immutable-tree" && cpr::calls==treeCalls);

    // Tokens are isolated; private metadata never creates disk payload files.
    const auto filesBefore=std::distance(fs::directory_iterator(runtime/"webupdate_cache"),fs::directory_iterator{});
    queue(200,"private-one"); GitHubProviderGet(commit,"secret-one",false);
    assert(cpr::lastHeaders.at("Authorization")=="Bearer secret-one");
    queue(200,"private-two"); GitHubProviderGet(commit,"secret-two",false);
    assert(cpr::lastHeaders.at("Authorization")=="Bearer secret-two");
    assert(std::distance(fs::directory_iterator(runtime/"webupdate_cache"),fs::directory_iterator{})==filesBefore);
    clearMemory(); queue(200,"private-refresh");
    assert(GitHubProviderGet(commit,"secret-one",false).text=="private-refresh");

    // Primary exhaustion is not retried, including across plugin reloads.
    const std::string other="https://api.github.com/repos/test/repo/commits/other";
    queue(403,"limited",{{"X-RateLimit-Remaining","0"},{"X-RateLimit-Reset",std::to_string(fakeNow+1800)}});
    GitHubProviderGet(other,"",false); const int limitedCalls=cpr::calls;
    assert(GitHubProviderGet(other,"",false).status_code==429 && cpr::calls==limitedCalls);
    clearMemory();
    assert(GitHubProviderGet(other,"",false).status_code==429 && cpr::calls==limitedCalls);
    // Safe immutable cached reads remain available during cooldown.
    assert(GitHubProviderGet(tree,"",false).text=="immutable-tree" && cpr::calls==limitedCalls);
    fakeNow += 1802; queue(200,"recovered");
    assert(GitHubProviderGet(other,"",false).text=="recovered");

    // Secondary Retry-After > 60 sec remains intact; token scope is separate.
    queue(429,"secondary",{{"Retry-After","180"}});
    GitHubProviderGet(other,"rate-token",false); const int secondaryCalls=cpr::calls;
    fakeNow += 61;
    assert(GitHubProviderGet(other,"rate-token",false).status_code==429 && cpr::calls==secondaryCalls);
    fakeNow += 121; queue(200,"secondary-recovered");
    assert(GitHubProviderGet(other,"rate-token",false).text=="secondary-recovered");
    queue(403,"You have exceeded a secondary rate limit.");
    GitHubProviderGet(other,"secondary-token",false); const int bodyCalls=cpr::calls;
    assert(GitHubProviderGet(other,"secondary-token",false).status_code==429 && cpr::calls==bodyCalls);
    // HTTP-date Retry-After must also gate, not silently cap the delay.
    const auto dateEpoch=static_cast<time_t>(fakeNow+300); auto date=*std::gmtime(&dateEpoch);
    char dateText[100]; std::strftime(dateText,sizeof(dateText),"%a, %d %b %Y %H:%M:%S GMT",&date);
    queue(429,"date",{{"Retry-After",dateText}});
    GitHubProviderGet(other,"date-token",false); const int dateCalls=cpr::calls;
    fakeNow += 180;
    assert(GitHubProviderGet(other,"date-token",false).status_code==429 && cpr::calls==dateCalls);

    // Successful final-budget responses are returned but block uncached calls.
    queue(200,"last-success",{{"x-ratelimit-remaining","0"},{"x-ratelimit-reset",std::to_string(fakeNow+300)}});
    assert(GitHubProviderGet(other,"last-token",false).text=="last-success");
    const int lastCalls=cpr::calls;
    assert(GitHubProviderGet(other+"-new","last-token",false).status_code==429 && cpr::calls==lastCalls);

    // Ordinary permissions and transient failures retain distinct behavior.
    queue(403,"forbidden"); GitHubProviderGet(other,"permission-token",false);
    queue(200,"permission-fixed"); assert(GitHubProviderGet(other,"permission-token",false).text=="permission-fixed");
    queue(500); queue(200,"retry-fixed");
    assert(GitHubProviderGet(other,"retry-token",false).text=="retry-fixed");
    mutexReady=false; const int lockCalls=cpr::calls;
    assert(GitHubProviderGet(other,"",false).status_code==429 && cpr::calls==lockCalls); mutexReady=true;

    // Public raw requests neither leak tokens nor share the API cooldown.
    mq2webupdate::profiles::Profile profile; profile.owner="test"; profile.repository="repo";
    mq2webupdate::providers::GitHubProviderAdapter provider;
    const auto raw=provider.FileRequest(profile,sha,"lua/a #?.lua");
    assert(!raw.requiresAuthentication && raw.url=="https://raw.githubusercontent.com/test/repo/"+sha+"/lua/a%20%23%3F.lua");
    queue(200,"bytes"); assert(GitHubProviderGet(raw.url,"secret",true).text=="bytes");
    assert(!cpr::lastHeaders.count("Authorization"));
    profile.privateRepository=true; const auto priv=provider.FileRequest(profile,sha,"lua/a.lua");
    assert(priv.requiresAuthentication && priv.url.find("api.github.com/repos/test/repo/contents/lua/a.lua?ref="+sha)!=std::string::npos);

    // Actual stage preflight suppresses matching text/binary and dangling links.
    const auto path=runtime/"test.lua";
    WriteFileBinaryAtomic(path,"hello\r\n");
    TestRemote remote{ComputeGitBlobSha("hello\n"),"test.lua","test.lua"};
    assert(StageDecision(path,remote,false,true).fileResults[0].status=="SAME");
    assert(StageDecision(path,remote,true,true).fileResults[0].status=="SAME");
    remote.destinationRelativePath="test.dll";
    assert(StageDecision(path,remote,false,true).fileResults[0].status=="DOWNLOAD");
    remote.gitObjectSha=ComputeGitBlobSha("hello\r\n");
    assert(StageDecision(path,remote,false,true).fileResults[0].status=="SAME");
    assert(StageDecision(path,remote,true,false).fileResults[0].status=="PROTECTED");
    assert(StageDecision(path,remote,false,false).fileResults[0].status=="DOWNLOAD");
    fs::remove(path); assert(StageDecision(path,remote,false,true).errorCount==1);
    remote.gitObjectSha=ComputeGitBlobSha("valid"); remote.expectedSize=5;
    assert(DownloadMatches({200,"valid",{},false},remote));
    assert(!DownloadMatches({200,"wrong",{},false},remote));
    assert(!DownloadMatches({200,"valid-long",{},false},remote));
    queue(503,"busy",{{"Retry-After","600"}});
    GitHubProviderGet(other,"server-token",false); const int serverCalls=cpr::calls;
    fakeNow += 61;
    assert(GitHubProviderGet(other,"server-token",false).status_code==429 && cpr::calls==serverCalls);
    assert(cpr::replies.empty());
    std::cout << "WebUpdate coordinator/cache/cooldown/provider/stage regressions passed\n";
}
'''.replace('STAGE_PREFIX',stage_prefix).replace('INTEGRITY',integrity)
with tempfile.TemporaryDirectory() as directory:
    directory=Path(directory)
    fixture=directory/'network.cpp'
    fixture.write_text(provider_code + sha + normalize + text_type + coordinator + tail)
    executable=directory/'network-test'
    subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Wno-deprecated-declarations','-I',str(root),str(fixture),'-lcrypto','-lcurl','-pthread','-o',str(executable)],check=True)
    subprocess.run([str(executable),str(directory/'runtime')],check=True)
