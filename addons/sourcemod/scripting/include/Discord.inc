#if defined _Discord_Included
	#endinput
#endif
#define _Discord_Included

native bool Discord_SendMessage(char sWebhook[64], char sMessageDiscord[4096]);

public SharedPlugin __pl_Discord =
{
	name = "Discord",
	file = "Discord.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public __pl_Discord_SetNTVOptional()
{
	MarkNativeAsOptional("Discord_SendMessage");
}
#endif
