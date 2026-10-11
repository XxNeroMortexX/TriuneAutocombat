#pragma once

// Created By: NeroMorte - request/cache policy independent of HTTP and MQ.
#include <algorithm>
#include <cstdint>
#include <limits>
#include <string>

namespace mq2webupdate::network
{
    inline std::int64_t PositiveInteger(const std::string& text)
    {
        if (text.empty() || text.find_first_not_of("0123456789") != std::string::npos)
            return 0;
        try { return std::stoll(text); }
        catch (...) { return 0; }
    }

    inline std::int64_t CooldownUntil(
        long status, const std::string& remaining, const std::string& reset,
        std::int64_t retrySeconds, bool secondaryLimit, std::int64_t now)
    {
        std::int64_t until = 0;
        if (remaining == "0")
        {
            const auto resetEpoch = PositiveInteger(reset);
            until = std::max(now + 60, resetEpoch == std::numeric_limits<std::int64_t>::max()
                ? resetEpoch : resetEpoch + 1);
        }
        if (status == 429 || (status == 403 && (retrySeconds > 0 || secondaryLimit)))
        {
            const auto delay = std::max<std::int64_t>(60, retrySeconds);
            until = std::max(until, now + std::min(
                delay, std::numeric_limits<std::int64_t>::max() - now - 1) + 1);
        }
        return until;
    }

    inline bool IsImmutableTreeUrl(const std::string& url)
    {
        const auto begin = url.find("/git/trees/");
        if (begin == std::string::npos) return false;
        const auto sha = url.substr(begin + 11, 40);
        return sha.size() == 40 &&
            sha.find_first_not_of("0123456789abcdefABCDEF") == std::string::npos &&
            url.substr(begin + 51) == "?recursive=1";
    }

    inline int MetadataCacheSeconds(const std::string& url, bool rawContent)
    {
        if (rawContent || url.rfind("https://api.github.com/repos/", 0) != 0)
            return 0;
        if (IsImmutableTreeUrl(url)) return 86400;
        if (url.find("/commits/") != std::string::npos) return 30;
        return 0;
    }
}
