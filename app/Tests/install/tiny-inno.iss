; Test installers for the add-a-game checks (make-installers.sh). Defines:
;   Name, Exe (installed program name), Span (1: data in setup-1.bin, with a hanging redistributable step),
;   Out, Base (output file name without .exe), Src (folder with TinyGame.exe and vc_redist.x64.exe)
[Setup]
AppName={#Name}
AppVersion=1.0.2
DefaultDirName={autopf}\{#Name}
DefaultGroupName={#Name}
OutputDir={#Out}
OutputBaseFilename={#Base}
Compression=lzma2
ArchitecturesInstallIn64BitMode=x64compatible
#if Span == "1"
DiskSpanning=yes
#endif

[Files]
Source: "{#Src}\TinyGame.exe"; DestDir: "{app}"; DestName: "{#Exe}"
#if Span == "1"
Source: "{#Src}\TinyGame.exe"; DestDir: "{app}"; DestName: "UnityCrashHandler64.exe"
Source: "{#Src}\vc_redist.x64.exe"; DestDir: "{app}\_Redist"
#endif

[Icons]
Name: "{group}\{#Name}"; Filename: "{app}\{#Exe}"

#if Span == "1"
[Run]
Filename: "{app}\_Redist\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; Flags: waituntilterminated
#endif
