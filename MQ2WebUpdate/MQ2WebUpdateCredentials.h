#pragma once

#include "MQ2WebUpdateProfiles.h"

#include <string>

#ifdef _WIN32
#include <windows.h>
#include <wincred.h>
#pragma comment(lib, "Advapi32.lib")
#endif

namespace mq2webupdate::credentials
{
    inline std::wstring Utf8ToWide(const std::string& value)
    {
#ifdef _WIN32
        if (value.empty())
            return {};

        const int required = MultiByteToWideChar(
            CP_UTF8, MB_ERR_INVALID_CHARS,
            value.data(), static_cast<int>(value.size()),
            nullptr, 0);

        if (required <= 0)
            return {};

        std::wstring output(static_cast<std::size_t>(required), L'\0');

        if (MultiByteToWideChar(
                CP_UTF8, MB_ERR_INVALID_CHARS,
                value.data(), static_cast<int>(value.size()),
                output.data(), required) != required)
        {
            return {};
        }

        return output;
#else
        return std::wstring(value.begin(), value.end());
#endif
    }

    inline std::wstring CredentialTarget(const std::string& profileId)
    {
        return L"MQ2WebUpdate/GitHub/" + Utf8ToWide(profileId);
    }

    inline bool IsPlausibleGitHubToken(const std::string& token)
    {
        if (token.size() < 20 || token.size() > 512)
            return false;

        for (unsigned char ch : token)
        {
            if (!(std::isalnum(ch) || ch == '_' || ch == '-'))
                return false;
        }

        return true;
    }

    inline void SecureClear(std::string& value)
    {
        volatile char* bytes = value.empty()
            ? nullptr
            : const_cast<volatile char*>(value.data());

        for (std::size_t i = 0; bytes && i < value.size(); ++i)
            bytes[i] = 0;

        value.clear();
        value.shrink_to_fit();
    }

    class ScopedSecret
    {
    public:
        ScopedSecret() = default;
        ~ScopedSecret() { SecureClear(value); }
        ScopedSecret(const ScopedSecret&) = delete;
        ScopedSecret& operator=(const ScopedSecret&) = delete;
        std::string value;
    };

#ifdef _WIN32
    inline bool StoreGitHubToken(
        const std::string& profileId,
        const std::string& token,
        std::string& error)
    {
        if (!mq2webupdate::profiles::IsAsciiIdentifier(profileId) ||
            !IsPlausibleGitHubToken(token))
        {
            error = "Profile ID or GitHub token format is invalid.";
            return false;
        }

        const std::wstring target = CredentialTarget(profileId);
        CREDENTIALW credential = {};
        credential.Type = CRED_TYPE_GENERIC;
        credential.TargetName = const_cast<LPWSTR>(target.c_str());
        credential.CredentialBlobSize = static_cast<DWORD>(token.size());
        credential.CredentialBlob = reinterpret_cast<LPBYTE>(
            const_cast<char*>(token.data()));
        credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
        credential.UserName = const_cast<LPWSTR>(L"GitHubToken");

        if (!CredWriteW(&credential, 0))
        {
            error = "Windows Credential Manager rejected the GitHub token.";
            return false;
        }

        error.clear();
        return true;
    }

    inline bool ReadGitHubToken(
        const std::string& profileId,
        std::string& token,
        std::string& error)
    {
        token.clear();

        if (!mq2webupdate::profiles::IsAsciiIdentifier(profileId))
        {
            error = "Profile ID is invalid.";
            return false;
        }

        PCREDENTIALW credential = nullptr;
        const std::wstring target = CredentialTarget(profileId);

        if (!CredReadW(
                target.c_str(),
                CRED_TYPE_GENERIC,
                0,
                &credential))
        {
            error = GetLastError() == ERROR_NOT_FOUND
                ? "No GitHub credential is stored for this profile."
                : "Windows Credential Manager could not read the GitHub token.";
            return false;
        }

        token.assign(
            reinterpret_cast<const char*>(credential->CredentialBlob),
            static_cast<std::size_t>(credential->CredentialBlobSize));
        CredFree(credential);

        if (!IsPlausibleGitHubToken(token))
        {
            SecureClear(token);
            error = "Stored GitHub credential has an invalid format.";
            return false;
        }

        error.clear();
        return true;
    }

    inline bool HasGitHubToken(const std::string& profileId)
    {
        std::string token;
        std::string error;
        const bool found = ReadGitHubToken(profileId, token, error);
        SecureClear(token);
        return found;
    }

    inline bool DeleteGitHubToken(
        const std::string& profileId,
        std::string& error)
    {
        if (!mq2webupdate::profiles::IsAsciiIdentifier(profileId))
        {
            error = "Profile ID is invalid.";
            return false;
        }

        const std::wstring target = CredentialTarget(profileId);

        if (!CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0))
        {
            if (GetLastError() == ERROR_NOT_FOUND)
            {
                error.clear();
                return true;
            }

            error = "Windows Credential Manager could not remove the GitHub token.";
            return false;
        }

        error.clear();
        return true;
    }
#endif
}
