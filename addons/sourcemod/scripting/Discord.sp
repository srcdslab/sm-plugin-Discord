#include <sourcemod>
#include <SteamWorks>
#include <sourcecomms>

#define PLUGIN_VERSION "1.0"

#pragma newdecls required

ArrayList g_aMsgs = null;
ArrayList g_aWebhook = null;

Handle g_hTimer = null;

bool g_bSending;
bool g_bSlowdown;

public Plugin myinfo = 
{
	name = "Discord API",
	author = "maxime1907, inGame",
	description = "Interact with the Discord API",
	version = PLUGIN_VERSION,
	url = "https://nide.gg"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("Discord_SendMessage", Native_SendMessage);
	RegPluginLibrary("Discord");
	return APLRes_Success;
}

public void OnMapStart()
{
	RestartMessageTimer(false);
}

public void OnMapEnd()
{
	g_hTimer = null;
}

public any Native_SendMessage(Handle plugin, int numParams)
{
    char sWebhook[64]
    GetNativeString(1, sWebhook, sizeof(sWebhook));

    char sMessageDiscord[4096];
    GetNativeString(2, sMessageDiscord, sizeof(sMessageDiscord));

    char sUrl[512];
    if(!GetWebHook(sWebhook, sUrl, sizeof(sUrl)))
    {
        LogError("Webhook config not found or invalid! Webhook: %s Url: %s", sWebhook, sUrl);
        LogError("Message: %s", sMessageDiscord);
        return false;
    }

    StoreMsg(sWebhook, sMessageDiscord);
    return true;
}

void StoreMsg(char sWebhook[64], char sMessageDiscord[4096])
{
	char sUrl[512];
	if(!GetWebHook(sWebhook, sUrl, sizeof(sUrl)))
	{
		LogError("Webhook config not found or invalid! Webhook: %s Url: %s", sWebhook, sUrl);
		LogError("Message: %s", sMessageDiscord);
		return;
	}

	// Sanity checks
	if (StrContains(sMessageDiscord, "\\") != -1 && StrContains(sMessageDiscord, "\\n") == -1)
		ReplaceString(sMessageDiscord, sizeof(sMessageDiscord), "\\", "\\\\");

	// If the message dosn't start with a '{' it's not for a JSON formated message, lets fix that!
	if(StrContains(sMessageDiscord, "{") != 0)
	{
		// Sanity checks
		if(StrContains(sMessageDiscord, "\"") != -1)
			ReplaceString(sMessageDiscord, sizeof(sMessageDiscord), "\"", "\\\"");

		Format(sMessageDiscord, sizeof(sMessageDiscord), "{\"content\":\"%s\"}", sMessageDiscord);
	}

	// Re-Format for Slack
	if(StrContains(sUrl, "slack") != -1)
		ReplaceString(sMessageDiscord, sizeof(sMessageDiscord), "\"content\":", "\"text\":");

	if (g_aWebhook == null)
	{
		g_aWebhook = new ArrayList(64);
		g_aMsgs = new ArrayList(4096);
	}

	g_aWebhook.PushString(sWebhook);
	g_aMsgs.PushString(sMessageDiscord);
}

public Action Timer_SendNextMessage(Handle timer, any data)
{
	SendNextMsg();
	return Plugin_Continue;
}

void SendNextMsg()
{
	// We are still waiting for a reply from our last msg
	if(g_bSending)
		return;

	// Nothing to send
	if(g_aWebhook == null || g_aWebhook.Length < 1)
		return;

	char sWebhook[64]
	g_aWebhook.GetString(0, sWebhook, sizeof(sWebhook));
	
	char sMessage[4096];
	g_aMsgs.GetString(0, sMessage, sizeof(sMessage));
	
	char sUrl[512];
	if(!GetWebHook(sWebhook, sUrl, sizeof(sUrl)))
	{
		LogError("Webhook config not found or invalid! Webhook: %s Url: %s", sWebhook, sUrl);
		LogError("Message: %s", sMessage);
		return;
	}

	Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, sUrl);
	if(!hRequest || !SteamWorks_SetHTTPCallbacks(hRequest, view_as<SteamWorksHTTPRequestCompleted>(OnRequestComplete)) 
				|| !SteamWorks_SetHTTPRequestRawPostBody(hRequest, "application/json", sMessage, strlen(sMessage))
				|| !SteamWorks_SendHTTPRequest(hRequest))
	{
		delete hRequest;
		LogError("SendNextMsg: Failed To Send Message");
		return;
	}

	// Don't Send new messages aslong we wait for a reply from this one
	g_bSending = true;
}

public int OnRequestComplete(Handle hRequest, bool bFailed, bool bRequestSuccessful, EHTTPStatusCode eStatusCode)
{
	// This should not happen!
	if(bFailed || !bRequestSuccessful)
	{
		LogError("[OnRequestComplete] Request failed");
	}
	// Seems like the API is busy or too many message send recently
	else if(eStatusCode == k_EHTTPStatusCode429TooManyRequests || eStatusCode == k_EHTTPStatusCode500InternalServerError)
	{
		if(!g_bSlowdown)
			RestartMessageTimer(true);
	}
	// Wrong msg format, API doesn't like it
	else if(eStatusCode == k_EHTTPStatusCode400BadRequest)
	{
		char sMessage[4096];
		g_aMsgs.GetString(0, sMessage, sizeof(sMessage));

		LogError("[OnRequestComplete] Bad Request! Error Code: [400]. Check your message, the API doesn't like it! Message: \"%s\"", sMessage); 

		// Remove it, the API will never accept it like this.
		g_aWebhook.Erase(0);
		g_aMsgs.Erase(0);
	}
	else if(eStatusCode == k_EHTTPStatusCode200OK || eStatusCode == k_EHTTPStatusCode204NoContent)
	{
		if(g_bSlowdown)
			RestartMessageTimer(false);

		g_aWebhook.Erase(0);
		g_aMsgs.Erase(0);
	}
	// Unknown error
	else
	{
		LogError("[OnRequestComplete] Error Code: [%d]", eStatusCode);

		g_aWebhook.Erase(0);
		g_aMsgs.Erase(0);
	}

	delete hRequest;
	g_bSending = false;
}

void RestartMessageTimer(bool slowdown)
{
	g_bSlowdown = slowdown;

	if(g_hTimer != null)
		delete g_hTimer;

	g_hTimer = CreateTimer(g_bSlowdown ? 1.0 : 0.1, Timer_SendNextMessage, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

bool GetWebHook(const char[] sWebhook, char[] sUrl, int iLength)
{
	KeyValues kv = new KeyValues("Discord");

	char sFile[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sFile, sizeof(sFile), "configs/discord.cfg");

	if (!FileExists(sFile))
	{
		SetFailState("[GetWebHook] \"%s\" not found!", sFile);
		return false;
	}

	kv.ImportFromFile(sFile);

	if (!kv.GotoFirstSubKey())
	{
		SetFailState("[GetWebHook] Can't find webhook for \"%s\"!", sFile);
		return false;
	}
	
	char sBuffer[64];

	do
	{
		kv.GetSectionName(sBuffer, sizeof(sBuffer));

		if(StrEqual(sBuffer, sWebhook, false))
		{
			kv.GetString("url", sUrl, iLength);
			delete kv;
			return true;
		}
	}
	while (kv.GotoNextKey());

	delete kv;

	return false;
}