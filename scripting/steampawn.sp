/**
 * SteamPawn
 */
#pragma semicolon 1
#include <sourcemod>

#include <sdktools>
// Mark dhooks as optional since it's not available for Linux x64 yet
#undef REQUIRE_EXTENSIONS
#include <dhooks>
#define REQUIRE_EXTENSIONS

#include <stocksoup/convars>
#include <stocksoup/memory>

#tryinclude <virtual_address>

#pragma newdecls required

#define ARCH_X86 0
#define ARCH_X64 1

#define PLUGIN_VERSION "1.2.0"
public Plugin myinfo = {
	name = "SteamPawn",
	author = "nosoop",
	description = "Some SteamWorks functionality.",
	version = PLUGIN_VERSION,
	url = "https://github.com/nosoop/SM-SteamPawn"
}

Handle g_SDKCallGetSteam3Server;
Handle g_SDKCallIsLoggedOn;

Handle g_DHookRestartRequested;

int g_nFakePorts;
Address g_pnFakeIP;
Address g_parFakePorts;
Address g_pSteam3Server;

GlobalForward g_FwdRestartRequested;

public APLRes AskPluginLoad2(Handle hPlugin, bool late, char[] error, int maxlen) {
	RegPluginLibrary("steampawn");
	
	CreateNative("SteamPawn_IsSteamConnected", Native_IsSteamConnected);
	CreateNative("SteamPawn_GetSDRFakeIP", Native_GetSDRFakeIP);
	CreateNative("SteamPawn_GetSDRFakePort", Native_GetSDRFakePort);
	
	return APLRes_Success;
}

public void OnPluginStart() {
	GameData hGameConf = new GameData("steampawn");
	if (!hGameConf) {
		SetFailState("Failed to load gamedata (steampawn).");
	}
	
	bool isDhooksAvailable = LibraryExists("dhooks");

	if (isDhooksAvailable) {
		g_DHookRestartRequested = DHookCreateFromConf(hGameConf,
				"ISteamGameServer::WasRestartRequested()");
		if (!g_DHookRestartRequested) {
			SetFailState("Failed to create virtual hook for "
					... "ISteamGameServer::WasRestartRequested()");
		}
	}
	else {
		LogMessage("Dhooks is not available, SteamPawn_OnRestartRequested forward won't be called.");
	}

	int arch = hGameConf.GetOffset("Arch");

	if (arch == -1) {
		SetFailState("Failed to determine the server's architecture. "
				... "SteamPawn's gamedata file may be outdated!");
	}

#if defined _virtual_address_included

	StartPrepSDKCall(SDKCall_Static);
	PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "Steam3Server()");
	PrepSDKCall_SetReturnInfo(SDKType_VirtualAddress, SDKPass_Plain);
	g_SDKCallGetSteam3Server = EndPrepSDKCall();
	if (!g_SDKCallGetSteam3Server) {
		g_pSteam3Server = GameConfGetAddress(hGameConf, "s_Steam3Server");
		if (!g_pSteam3Server) {
			SetFailState("Failed to get address to Steam3Server instance");
		}
	} else {
		g_pSteam3Server = SDKCall(g_SDKCallGetSteam3Server);
	}
	
	StartPrepSDKCall(SDKCall_VirtualAddress);
	PrepSDKCall_SetFromConf(hGameConf, SDKConf_Virtual, "ISteamGameServer::BLoggedOn()");
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	g_SDKCallIsLoggedOn = EndPrepSDKCall();
	if (!g_SDKCallIsLoggedOn) {
		SetFailState("Failed to initialize SDKCall to ISteamGameServer::BLoggedOn()");
	}

#else
	// No virtual address (IE: compiled against SM 1.12)

	if (arch == ARCH_X64) {
		SetFailState("Virtual Addresses (SM 1.13+) is required for x64!");
	}

	StartPrepSDKCall(SDKCall_Static);
	PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "Steam3Server()");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_SDKCallGetSteam3Server = EndPrepSDKCall();
	if (!g_SDKCallGetSteam3Server) {
		g_pSteam3Server = GameConfGetAddress(hGameConf, "s_Steam3Server");
		if (!g_pSteam3Server) {
			SetFailState("Failed to get address to Steam3Server instance");
		}
	} else {
		g_pSteam3Server = SDKCall(g_SDKCallGetSteam3Server);
	}
	
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(hGameConf, SDKConf_Virtual, "ISteamGameServer::BLoggedOn()");
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	g_SDKCallIsLoggedOn = EndPrepSDKCall();
	if (!g_SDKCallIsLoggedOn) {
		SetFailState("Failed to initialize SDKCall to ISteamGameServer::BLoggedOn()");
	}

#endif
	
	g_pnFakeIP = GameConfGetAddress(hGameConf, "g_nFakeIP");
	g_parFakePorts = GameConfGetAddress(hGameConf, "g_arFakePorts");
	
	char strNumFakePorts[4];
	GameConfGetKeyValue(hGameConf, "NumFakePorts", strNumFakePorts, sizeof(strNumFakePorts));
	g_nFakePorts = StringToInt(strNumFakePorts);
	
	delete hGameConf;
	
	if (g_DHookRestartRequested != null) {
		Address pSteamGameServer = GetSteamGameServer();
		DHookRaw(g_DHookRestartRequested, true, pSteamGameServer, .callback = OnRestartRequested);
	}
	
	g_FwdRestartRequested = CreateGlobalForward("SteamPawn_OnRestartRequested", ET_Ignore);
	
	CreateVersionConVar("steampawn_version");
}

MRESReturn OnRestartRequested(Address pSteamGameServer, Handle hReturn) {
	bool bShouldRestart = !!DHookGetReturn(hReturn);
	if (bShouldRestart) {
		Call_StartForward(g_FwdRestartRequested);
		Call_Finish();
	}

	return MRES_Ignored;
}

int Native_IsSteamConnected(Handle plugin, int argc) {
	Address pSteamGameServer = GetSteamGameServer();
	if (!pSteamGameServer) {
		return false;
	}
	
	return !!SDKCall(g_SDKCallIsLoggedOn, pSteamGameServer);
}

int Native_GetSDRFakeIP(Handle plugin, int argc) {
	return GetSDRFakeIP();
}

int Native_GetSDRFakePort(Handle plugin, int argc) {
	int num = GetNativeCell(1);
	return GetSDRFakePort(num);
}

Address GetSteamGameServer() {
	return DereferencePointer(g_pSteam3Server + view_as<Address>(0x04));
}

int GetSDRFakeIP() {
	if (!g_pnFakeIP) {
		return 0;
	}
	return LoadFromAddress(g_pnFakeIP, NumberType_Int32);
}

int GetSDRFakePort(int num) {
	if (!g_parFakePorts || num < 0 || num >= g_nFakePorts) {
		return 0;
	}
	return LoadFromAddress(g_parFakePorts + view_as<Address>((num * 0x2)), NumberType_Int16);
}
