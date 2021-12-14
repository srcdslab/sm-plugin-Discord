#include <sourcemod>
#include <ripext>
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

	JSONObject message = new JSONObject();

	if(StrContains(sUrl, "slack") != -1)
		message.SetString("text", sMessageDiscord); // Slack
	else
		message.SetString("content", sMessageDiscord); // Discord

	if (g_aWebhook == null)
	{
		g_aWebhook = new ArrayList(64);
		g_aMsgs = new ArrayList(4096);
	}

	g_aWebhook.PushString(sWebhook);
	g_aMsgs.Push(message);
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
	
	JSONObject message = g_aMsgs.Get(0);

	char sUrl[512];
	if(!GetWebHook(sWebhook, sUrl, sizeof(sUrl)))
	{
		LogError("Webhook config not found or invalid! Webhook: %s Url: %s", sWebhook, sUrl);
		return;
	}

	HTTPRequest request = new HTTPRequest(sUrl);

	request.Post(message, OnMessageSended);

	// Don't Send new messages aslong we wait for a reply from this one
	g_bSending = true;
}

void OnMessageSended(HTTPResponse response, any value)
{
	JSONObject message = g_aMsgs.Get(0);

	// Seems like the API is busy or too many message send recently
	if(response.Status == HTTPStatus_TooManyRequests || response.Status == HTTPStatus_InternalServerError)
	{
		if(!g_bSlowdown)
			RestartMessageTimer(true);
	}
	// Wrong msg format, API doesn't like it
	else if(response.Status == HTTPStatus_BadRequest)
	{
		char sMessage[4096];
		message.GetString("content", sMessage, sizeof(sMessage));
		if (!sMessage[0])
			message.GetString("text", sMessage, sizeof(sMessage));

		LogError("[OnRequestComplete] Bad Request! Error Code: [400]. Check your message, the API doesn't like it! Message: \"%s\"", sMessage); 

		// Remove it, the API will never accept it like this.
		delete message;
		g_aWebhook.Erase(0);
		g_aMsgs.Erase(0);
	}
	else if(response.Status == HTTPStatus_OK || response.Status == HTTPStatus_NoContent)
	{
		if(g_bSlowdown)
			RestartMessageTimer(false);

		delete message;
		g_aWebhook.Erase(0);
		g_aMsgs.Erase(0);
	}
	// Unknown error
	else
	{
		LogError("[OnRequestComplete] Error Code: [%d]", response.Status);

		delete message;
		g_aWebhook.Erase(0);
		g_aMsgs.Erase(0);
	}

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