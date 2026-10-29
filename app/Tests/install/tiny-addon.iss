; An add-on installer for the add-a-game checks: puts Extra.txt into the game's folder. Defines: Out, Base, Src.
[Setup]
AppName=Tiny GOG Extra
AppVersion=1.0
DefaultDirName={autopf}\Tiny GOG
DisableDirPage=no
CreateAppDir=yes
Uninstallable=no
OutputDir={#Out}
OutputBaseFilename={#Base}
ArchitecturesInstallIn64BitMode=x64compatible

[Files]
Source: "{#Src}\Extra.txt"; DestDir: "{app}"
