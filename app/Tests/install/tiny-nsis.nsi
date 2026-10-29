; An NSIS test installer for the add-a-game checks. Defines: SRC (folder with TinyGame.exe), OUT (setup.exe path).
Unicode true
Name "Tiny NSIS Game"
OutFile "${OUT}"
InstallDir "$PROGRAMFILES64\Tiny NSIS Game"
RequestExecutionLevel admin

Section
  SetShellVarContext all
  SetOutPath "$INSTDIR"
  File "/oname=TinyNsisGame.exe" "${SRC}/TinyGame.exe"
  CreateDirectory "$SMPROGRAMS\Tiny NSIS Game"
  CreateShortcut "$SMPROGRAMS\Tiny NSIS Game\Tiny NSIS Game.lnk" "$INSTDIR\TinyNsisGame.exe"
  WriteUninstaller "$INSTDIR\uninstall.exe"
SectionEnd

Section "Uninstall"
  SetShellVarContext all
  Delete "$INSTDIR\TinyNsisGame.exe"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"
SectionEnd
