/* SteamAPI_Init through the bridge (AppID 480), report BLoggedOn and the persona name length.
 * Uses steam_api64's flat C exports, resolving the versioned accessors at runtime so any
 * recent steam_api64.dll works. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

typedef BOOL (__cdecl *init_fn)(void);
typedef int (__cdecl *init_flat_fn)(char *err);
typedef void (__cdecl *shutdown_fn)(void);
typedef void *(__cdecl *accessor_fn)(void);
typedef BOOL (__cdecl *logged_on_fn)(void *);
typedef const char *(__cdecl *persona_fn)(void *);

/* find the highest-versioned export starting with prefix, e.g. "SteamAPI_SteamUser_v" */
static FARPROC find_versioned(HMODULE mod, const char *prefix, char *found, size_t len)
{
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)((char *)mod + ((IMAGE_DOS_HEADER *)mod)->e_lfanew);
    IMAGE_DATA_DIRECTORY *dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    IMAGE_EXPORT_DIRECTORY *exp = (IMAGE_EXPORT_DIRECTORY *)((char *)mod + dir->VirtualAddress);
    DWORD *names = (DWORD *)((char *)mod + exp->AddressOfNames);
    const char *best = NULL;
    DWORD i;

    for (i = 0; i < exp->NumberOfNames; i++)
    {
        const char *name = (char *)mod + names[i];
        if (!strncmp(name, prefix, strlen(prefix)) && (!best || strcmp(name, best) > 0)) best = name;
    }
    if (!best) return NULL;
    snprintf(found, len, "%s", best);
    return GetProcAddress(mod, best);
}

int main(int argc, char **argv)
{
    const char *dll = argc > 1 ? argv[1] : "steam_api64.dll";
    HMODULE api, sc;
    init_fn init;
    init_flat_fn init_flat;
    shutdown_fn shutdown;
    accessor_fn user_acc, friends_acc;
    logged_on_fn logged_on;
    persona_fn persona;
    char uname[96] = "", fname[96] = "", path[MAX_PATH], err[1024] = "";
    void *user, *friends;
    BOOL ok;

    SetEnvironmentVariableA("SteamAppId", "480");
    SetEnvironmentVariableA("SteamGameId", "480");

    if (!(api = LoadLibraryA(dll))) { printf("FAIL LoadLibrary(%s) %lu\n", dll, GetLastError()); return 1; }
    GetModuleFileNameA(api, path, sizeof(path));
    printf("steam_api: %s\n", path);

    init_flat = (init_flat_fn)GetProcAddress(api, "SteamAPI_InitFlat");
    init = (init_fn)GetProcAddress(api, "SteamAPI_Init");
    shutdown = (shutdown_fn)GetProcAddress(api, "SteamAPI_Shutdown");
    if (init_flat)
    {
        int r = init_flat(err);
        printf("SteamAPI_InitFlat -> %d %s\n", r, err);
        ok = r == 0;
    }
    else if (init) ok = init(), printf("SteamAPI_Init -> %d\n", ok);
    else { printf("FAIL no SteamAPI_Init export\n"); return 1; }

    if ((sc = GetModuleHandleA("steamclient64.dll")))
    {
        GetModuleFileNameA(sc, path, sizeof(path));
        printf("steamclient64: %s\n", path);
    }
    if ((sc = GetModuleHandleA("lsteamclient.dll")))
    {
        GetModuleFileNameA(sc, path, sizeof(path));
        printf("lsteamclient: %s (bridge loaded)\n", path);
    }
    else printf("lsteamclient: not loaded\n");
    if (!ok) { printf("STEAM FAIL init\n"); return 1; }

    user_acc = (accessor_fn)find_versioned(api, "SteamAPI_SteamUser_v", uname, sizeof(uname));
    friends_acc = (accessor_fn)find_versioned(api, "SteamAPI_SteamFriends_v", fname, sizeof(fname));
    logged_on = (logged_on_fn)GetProcAddress(api, "SteamAPI_ISteamUser_BLoggedOn");
    persona = (persona_fn)GetProcAddress(api, "SteamAPI_ISteamFriends_GetPersonaName");
    if (!user_acc || !logged_on) { printf("FAIL no ISteamUser flat API\n"); return 1; }

    user = user_acc();
    ok = user && logged_on(user);
    printf("%s=%p BLoggedOn=%d\n", uname, user, ok);
    if (friends_acc && persona && (friends = friends_acc()))
    {
        const char *name = persona(friends);
        /* never print the name itself */
        printf("%s persona: <masked:%u chars>\n", fname, name ? (unsigned)strlen(name) : 0);
    }
    if (shutdown) shutdown();
    printf("%s\n", ok ? "STEAM OK" : "STEAM FAIL");
    return ok ? 0 : 1;
}
