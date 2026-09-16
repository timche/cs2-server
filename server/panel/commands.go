package main

type command struct {
	Trigger string
	Desc    string
}

type group struct {
	Title    string
	Note     string
	Commands []command
}

type link struct {
	Label string
	URL   string
}

// ChatControl runs in every mode, so its commands are listed once, above
// whatever the selected mode adds.
var sharedHelp = []group{{
	Title: "Every mode",
	Commands: []command{
		{Trigger: ".map <map>", Desc: "Change the map. A name without an underscore gets de_, so .map dust2 is de_dust2."},
		{Trigger: ".map <workshop ID/URL>", Desc: "Load a workshop map. MatchZy owns .map in its own mode, so there this one is .wmap."},
		{Trigger: ".rcon <command>", Desc: "Run a server command. Nothing is filtered."},
		{Trigger: ".aim", Desc: "Aim-map convars: rifles, free armour, no freeze time, endless rounds."},
		{Trigger: ".aimpistol", Desc: "The same for pistols."},
	},
}}

var matchzyHelp = []group{
	{
		Title: "Match",
		Note:  "Everyone is an admin here, so every player can run all of these.",
		Commands: []command{
			{Trigger: ".ready", Desc: "Ready up. .r is shorter, .unready and .ur take it back."},
			{Trigger: ".start", Desc: "Start the match without waiting for the rest."},
			{Trigger: ".stop", Desc: "Restore the current round. Both teams have to type it."},
			{Trigger: ".pause", Desc: "Pause at the next freeze time. .unpause resumes, and both teams have to type that one."},
			{Trigger: ".tac", Desc: "Take a tactical timeout."},
			{Trigger: ".stay", Desc: "Keep your side after winning the knife round. .switch takes the other one."},
			{Trigger: ".restart", Desc: "End the match and reset it."},
			{Trigger: ".restore <round>", Desc: "Restore the backup of a round by number."},
			{Trigger: ".roundknife", Desc: "Turn the knife round on or off."},
			{Trigger: ".readyrequired <n>", Desc: "How many players have to ready up. 0 means everyone connected."},
			{Trigger: ".team1 <name>", Desc: "Name the CT team. .team2 names the T team."},
			{Trigger: ".settings", Desc: "Print the current match settings."},
			{Trigger: ".wmap <workshop ID/URL>", Desc: "Load a workshop map. .map is MatchZy's here and takes plain names only."},
			{Trigger: ".help", Desc: "MatchZy's own command list, in chat."},
		},
	},
	{
		Title: "Practice",
		Note:  "Open practice mode first; the rest only work inside it.",
		Commands: []command{
			{Trigger: ".prac", Desc: "Open practice mode. .exitprac goes back to match mode."},
			{Trigger: ".spawn <n>", Desc: "Teleport to a competitive spawn. .ctspawn and .tspawn pick the side."},
			{Trigger: ".bestspawn", Desc: "Teleport to your team's closest spawn. .worstspawn takes the furthest."},
			{Trigger: ".showspawns", Desc: "Highlight every competitive spawn. .hidespawns clears them."},
			{Trigger: ".bot", Desc: "Put a bot where you stand. .crouchbot crouches it, .boost stands you on it, .nobots clears them."},
			{Trigger: ".noflash", Desc: "Stop flashes blinding you. You still blind everyone else."},
			{Trigger: ".god", Desc: "Take no damage. .dryrun stops you dealing any."},
			{Trigger: ".clear", Desc: "Clear the smokes and fires that are burning."},
			{Trigger: ".break", Desc: "Break the breakable glass, doors and vents."},
			{Trigger: ".ff", Desc: "Fast-forward twenty seconds."},
			{Trigger: ".rethrow", Desc: "Throw your last grenade again. .rethrowsmoke, .rethrowflash, .rethrownade and .rethrowmolotov pick a type."},
			{Trigger: ".last", Desc: "Teleport back to where you threw it from."},
			{Trigger: ".back <n>", Desc: "Teleport to an older throw. .throwindex <n> rethrows one, or several at once."},
			{Trigger: ".delay <seconds>", Desc: "Wait this long before a rethrow, for lineups that need two grenades."},
			{Trigger: ".timer", Desc: "Start a timer. Type it again to stop it and see how long the run took."},
			{Trigger: ".savenade <name>", Desc: "Save the lineup you are standing on. .ln <name> loads one back."},
			{Trigger: ".listnades", Desc: "List the saved lineups. .deletenade removes one, .importnade <code> takes someone else's."},
			{Trigger: ".savepos", Desc: "Remember where you stand. .loadpos puts you back."},
			{Trigger: ".solid", Desc: "Walk through teammates or not. .impacts shows bullet impacts, .traj shows grenade paths."},
			{Trigger: ".ct", Desc: "Change team. .t and .spec are the other two."},
			{Trigger: ".fas", Desc: "Put everyone else in spectator to watch you."},
		},
	},
}

var retakesHelp = []group{
	{
		Title: "Playing",
		Note:  "Retakes and the allocator answer ! and /, not the . that ChatControl and MatchZy use.",
		Commands: []command{
			{Trigger: "guns", Desc: "Open the loadout menu: primary, pistol, sniper, enemy weapons, Zeus. It applies next round."},
			{Trigger: "!gun <weapon>", Desc: "Set one weapon without the menu. Add T or CT for one side only."},
			{Trigger: "!removegun <weapon>", Desc: "Drop that preference again."},
			{Trigger: "!awp", Desc: "Ask for the AWP when the sniper goes round. !ssg asks for the Scout, !zeus for a Zeus."},
			{Trigger: "!nextround", Desc: "Vote on the next round's buy: pistol, half or full."},
			{Trigger: "!voices", Desc: "Mute the bombsite announcements, for you alone."},
		},
	},
	{
		Title: "Admin",
		Note:  "These ask CounterStrikeSharp, which knows only the Steam64 IDs in RETAKES_ADMIN_STEAM_IDS. Everyone-is-admin does not cover them and .rcon is no way round it.",
		Commands: []command{
			{Trigger: "!showspawns <A/B>", Desc: "Open the spawn editor on a bombsite. !hidespawns closes it."},
			{Trigger: "!addspawn <CT/T> <Y/N>", Desc: "Add a spawn where you stand. Y if the bomb can be planted from it."},
			{Trigger: "!removespawn", Desc: "Remove the nearest spawn. !nearestspawn teleports you to it first."},
			{Trigger: "!forcebombsite <A/B>", Desc: "Play one site only. !forcebombsitestop goes back to both."},
			{Trigger: "!scramble", Desc: "Scramble the teams next round."},
			{Trigger: "!setnextround <P/H/F>", Desc: "Force the next round's buy: pistol, half or full."},
			{Trigger: "!mapconfigs", Desc: "List the spawn configs for this map. !mapconfig <name> loads one."},
		},
	},
}

var chatcontrolHelp = []group{{
	Title: "Stock competitive",
	Note:  "No plugin but ChatControl is running, so the game is whatever the convars say. Set one up with .rcon.",
	Commands: []command{
		{Trigger: ".rcon mp_warmup_end", Desc: "End the warm-up and start playing."},
		{Trigger: ".rcon mp_restartgame 1", Desc: "Restart the game in a second."},
		{Trigger: ".rcon bot_add", Desc: "Add a bot. bot_kick clears them out again."},
		{Trigger: ".rcon mp_maxrounds 16", Desc: "Any convar at all: this one is the match length."},
	},
}}

var matchzyDocs = []link{{Label: "MatchZy", URL: "https://shobhit-pathak.github.io/MatchZy/"}}

var retakesDocs = []link{
	{Label: "cs2-retakes", URL: "https://github.com/B3none/cs2-retakes"},
	{Label: "RetakesAllocator", URL: "https://github.com/Micka2302/cs2-retakes-allocator-2.0"},
}

var chatcontrolDocs = []link{{Label: "ChatControl", URL: "https://github.com/timche/cs2-chat-control"}}
