Unicode true

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "nsDialogs.nsh"
!include "WinMessages.nsh"

!ifndef APP_VERSION
  !error "APP_VERSION is required"
!endif
!ifndef FILE_VERSION
  !error "FILE_VERSION is required"
!endif
!ifndef PAYLOAD_DIR
  !error "PAYLOAD_DIR is required"
!endif
!ifndef PAYLOAD_SIZE_KB
  !error "PAYLOAD_SIZE_KB is required"
!endif
!ifndef OUTPUT_FILE
  !error "OUTPUT_FILE is required"
!endif
!ifndef ICON_FILE
  !error "ICON_FILE is required"
!endif

!define PRODUCT_NAME "Zmusic"
!define APP_EXECUTABLE "zmusic.exe"
!define INSTALL_MARKER "zmusic.installed"
!define USERDATA_DIRECTORY "userdata"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zmusic"
!define FILE_ASSOC_PROGID "Zmusic.Audio"
!define APP_CAPABILITIES_KEY "Software\Zmusic\Capabilities"

Name "${PRODUCT_NAME}"
OutFile "${OUTPUT_FILE}"
WindowIcon on
InstallDir "$LOCALAPPDATA\Programs\Zmusic"
InstallDirRegKey HKCU "${UNINSTALL_KEY}" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 64
CRCCheck on
XPStyle on
ManifestDPIAware true
BrandingText "Zmusic"
ShowInstDetails hide
ShowUnInstDetails hide
AutoCloseWindow true

VIProductVersion "${FILE_VERSION}"
VIAddVersionKey /LANG=2052 "ProductName" "Zmusic"
VIAddVersionKey /LANG=2052 "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "FileDescription" "Zmusic Windows 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${FILE_VERSION}"
VIAddVersionKey /LANG=2052 "CompanyName" "Zmusic"
VIAddVersionKey /LANG=2052 "LegalCopyright" "Zmusic"

!define MUI_ABORTWARNING
!define MUI_ICON "${ICON_FILE}"
!define MUI_UNICON "${ICON_FILE}"
!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_RIGHT
!define MUI_HEADERIMAGE_BITMAP "${__FILEDIR__}\zmusic-header.bmp"
!define MUI_WELCOMEFINISHPAGE_BITMAP "${__FILEDIR__}\zmusic-welcome.bmp"
!define MUI_COMPONENTSPAGE_SMALLDESC
!define MUI_INSTFILESPAGE_PROGRESSBAR smooth
!define MUI_INSTFILESPAGE_FINISHHEADER_TEXT "安装完成"
!define MUI_INSTFILESPAGE_FINISHHEADER_SUBTEXT "Zmusic 已成功安装。"

!insertmacro MUI_PAGE_WELCOME
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE DirectoryPageLeave
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
Page custom FinishPageCreate FinishPageLeave

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

!insertmacro MUI_LANGUAGE "SimpChinese"

Var FinishDialog
Var LaunchAfterFinish

InstType "标准安装"

!macro CloseRunningZmusic
  DetailPrint "正在关闭已运行的 Zmusic..."
  nsExec::ExecToStack /TIMEOUT=5000 '"$SYSDIR\taskkill.exe" /F /IM "${APP_EXECUTABLE}"'
  Pop $0
  Pop $1
  Sleep 1000
!macroend

!macro RegisterAudioExtension EXT
  WriteRegStr HKCU "Software\Classes\${EXT}\OpenWithProgids" \
    "${FILE_ASSOC_PROGID}" ""
  WriteRegStr HKCU \
    "Software\Classes\Applications\${APP_EXECUTABLE}\SupportedTypes" \
    "${EXT}" ""
  WriteRegStr HKCU "${APP_CAPABILITIES_KEY}\FileAssociations" \
    "${EXT}" "${FILE_ASSOC_PROGID}"
!macroend

!macro UnregisterAudioExtension EXT
  DeleteRegValue HKCU "Software\Classes\${EXT}\OpenWithProgids" \
    "${FILE_ASSOC_PROGID}"
  DeleteRegValue HKCU \
    "Software\Classes\Applications\${APP_EXECUTABLE}\SupportedTypes" \
    "${EXT}"
  DeleteRegValue HKCU "${APP_CAPABILITIES_KEY}\FileAssociations" "${EXT}"
!macroend

Function NormalizeInstallDirectory
  ${GetRoot} "$INSTDIR" $0
  StrCmp "$0" "" done
  StrCmp "$INSTDIR" "$0" appendProductDirectory
  StrCmp "$INSTDIR" "$0\" appendProductDirectory
  StrCmp "$INSTDIR" "$0\." appendProductDirectory done
appendProductDirectory:
  StrCpy $INSTDIR "$0\${PRODUCT_NAME}"
done:
FunctionEnd

Function IsSafeInstallDirectory
  IfFileExists "$INSTDIR\${INSTALL_MARKER}" safe
  IfFileExists "$INSTDIR\${APP_EXECUTABLE}" safe
  IfFileExists "$INSTDIR\uninstall.exe" safe
  IfFileExists "$INSTDIR\file_selector_windows_plugin.dll" safe
  IfFileExists "$INSTDIR\flutter_windows.dll" safe
  IfFileExists "$INSTDIR\libmpv-2.dll" safe
  IfFileExists "$INSTDIR\data\app.so" safe scanFreshDirectory

scanFreshDirectory:
  ClearErrors
  FindFirst $0 $1 "$INSTDIR\*"
  IfErrors safe

scanNextEntry:
  StrCmp $1 "" scanComplete
  StrCmp $1 "." continueScan
  StrCmp $1 ".." continueScan
  StrCmp $1 "${USERDATA_DIRECTORY}" continueScan
  FindClose $0
  Push 0
  Return

continueScan:
  ClearErrors
  FindNext $0 $1
  IfErrors scanComplete
  Goto scanNextEntry

scanComplete:
  FindClose $0

safe:
  Push 1
FunctionEnd

Function DirectoryPageLeave
  Call NormalizeInstallDirectory
  Call IsSafeInstallDirectory
  Pop $0
  StrCmp $0 1 valid
  MessageBox MB_OK|MB_ICONEXCLAMATION \
    "安装位置包含其他文件，安装器不会删除这些内容。$\r$\n请选择空目录，或选择现有的 Zmusic 安装目录。"
  Abort
valid:
FunctionEnd

Function ValidateInstallDirectoryForInstall
  Call NormalizeInstallDirectory
  Call IsSafeInstallDirectory
  Pop $0
  StrCmp $0 1 valid
  SetErrorLevel 2
  Quit
valid:
FunctionEnd

Function RemoveExistingProgramFiles
  StrCpy $R0 0

cleanupRetry:
  ClearErrors
  Delete "$INSTDIR\${APP_EXECUTABLE}"
  Delete "$INSTDIR\*.dll"
  Delete "$INSTDIR\*.ico"
  Delete "$INSTDIR\cmake_install.cmake"
  Delete "$INSTDIR\uninstall.exe"
  RMDir /r "$INSTDIR\data"
  RMDir /r "$INSTDIR\CMakeFiles"
  IfErrors cleanupLocked cleanupDone

cleanupLocked:
  IntOp $R0 $R0 + 1
  IntCmp $R0 20 cleanupPrompt cleanupWait cleanupPrompt

cleanupWait:
  DetailPrint "程序文件仍被 Windows 占用，正在等待后继续安装..."
  Sleep 500
  Goto cleanupRetry

cleanupPrompt:
  MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION \
    "Zmusic 已退出，但 Windows 仍在占用部分程序文件。$\r$\n点击“重试”继续等待，或点击“取消”退出安装。" \
    IDRETRY cleanupReset IDCANCEL cleanupCancel

cleanupReset:
  StrCpy $R0 0
  !ifndef TEST_MODE
    !insertmacro CloseRunningZmusic
  !endif
  Goto cleanupRetry

cleanupCancel:
  SetErrorLevel 3
  Abort

cleanupDone:
FunctionEnd

Section "Zmusic 主程序（必需）" SEC_MAIN
  SectionIn RO
  SetShellVarContext current
  Call ValidateInstallDirectoryForInstall

  !ifndef TEST_MODE
    !insertmacro CloseRunningZmusic
  !endif

  DetailPrint "正在清理旧版本程序文件..."
  Call RemoveExistingProgramFiles

  SetOutPath "$INSTDIR"
  SetOverwrite on
  File /r "${PAYLOAD_DIR}\*.*"

  CreateDirectory "$INSTDIR\${USERDATA_DIRECTORY}"
  FileOpen $0 "$INSTDIR\${INSTALL_MARKER}" w
  FileWrite $0 "NSIS ${APP_VERSION}"
  FileClose $0

  WriteUninstaller "$INSTDIR\uninstall.exe"

  !ifndef TEST_MODE
    CreateDirectory "$SMPROGRAMS\Zmusic"
    CreateShortCut "$SMPROGRAMS\Zmusic\Zmusic.lnk" \
      "$INSTDIR\${APP_EXECUTABLE}" "" "$INSTDIR\app_icon.ico"
    CreateShortCut "$SMPROGRAMS\Zmusic\卸载 Zmusic.lnk" \
      "$INSTDIR\uninstall.exe" "" "$INSTDIR\app_icon.ico"

    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "Zmusic"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "Zmusic"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\${APP_EXECUTABLE}"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
    WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" ${PAYLOAD_SIZE_KB}
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1

    WriteRegStr HKCU "Software\Classes\${FILE_ASSOC_PROGID}" "" \
      "Zmusic 音频文件"
    WriteRegStr HKCU "Software\Classes\${FILE_ASSOC_PROGID}\DefaultIcon" "" \
      '"$INSTDIR\${APP_EXECUTABLE}",0'
    WriteRegStr HKCU \
      "Software\Classes\${FILE_ASSOC_PROGID}\shell\open\command" "" \
      '"$INSTDIR\${APP_EXECUTABLE}" "%1"'
    WriteRegStr HKCU "Software\Classes\Applications\${APP_EXECUTABLE}" \
      "FriendlyAppName" "Zmusic"
    WriteRegStr HKCU \
      "Software\Classes\Applications\${APP_EXECUTABLE}\DefaultIcon" "" \
      '"$INSTDIR\${APP_EXECUTABLE}",0'
    WriteRegStr HKCU \
      "Software\Classes\Applications\${APP_EXECUTABLE}\shell\open\command" \
      "" '"$INSTDIR\${APP_EXECUTABLE}" "%1"'
    WriteRegStr HKCU "${APP_CAPABILITIES_KEY}" "ApplicationName" "Zmusic"
    WriteRegStr HKCU "${APP_CAPABILITIES_KEY}" "ApplicationDescription" \
      "使用 Zmusic 播放音频文件"
    WriteRegStr HKCU "Software\RegisteredApplications" "Zmusic" \
      "${APP_CAPABILITIES_KEY}"
    !insertmacro RegisterAudioExtension ".mp3"
    !insertmacro RegisterAudioExtension ".flac"
    !insertmacro RegisterAudioExtension ".ape"
    !insertmacro RegisterAudioExtension ".m4a"
    !insertmacro RegisterAudioExtension ".ogg"
    !insertmacro RegisterAudioExtension ".opus"
    !insertmacro RegisterAudioExtension ".wav"
    !insertmacro RegisterAudioExtension ".aif"
    !insertmacro RegisterAudioExtension ".aiff"
    !insertmacro RegisterAudioExtension ".aifc"
    System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
  !endif
SectionEnd

Section "创建桌面快捷方式" SEC_DESKTOP
  SectionIn 1
  !ifndef TEST_MODE
    SetShellVarContext current
    CreateShortCut "$DESKTOP\Zmusic.lnk" \
      "$INSTDIR\${APP_EXECUTABLE}" "" "$INSTDIR\app_icon.ico"
  !endif
SectionEnd

LangString DESC_SEC_MAIN ${LANG_SIMPCHINESE} \
  "安装 Zmusic 主程序、播放引擎和运行库。"
LangString DESC_SEC_DESKTOP ${LANG_SIMPCHINESE} \
  "在桌面创建 Zmusic 快捷方式。"

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_MAIN} $(DESC_SEC_MAIN)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_DESKTOP} $(DESC_SEC_DESKTOP)
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Function FinishPageCreate
  !insertmacro MUI_HEADER_TEXT "安装完成" "Zmusic 已成功安装到您的计算机。"
  nsDialogs::Create 1018
  Pop $FinishDialog
  StrCmp $FinishDialog error 0 +2
  Abort

  ${NSD_CreateLabel} 0 8u 100% 28u \
    "Zmusic 已安装在：$\r$\n$INSTDIR"
  Pop $0
  ${NSD_CreateLabel} 0 48u 100% 18u \
    "点击“打开”启动 Zmusic，或点击“完成”退出安装向导。"
  Pop $0

  StrCpy $LaunchAfterFinish 0
  GetDlgItem $R0 $HWNDPARENT 1
  GetDlgItem $R1 $HWNDPARENT 3
  GetDlgItem $R2 $HWNDPARENT 2

  System::Call 'user32::GetWindowRect(p$R0,@r3)'
  System::Call 'user32::MapWindowPoints(p0,p$HWNDPARENT,pr3,i2)'
  System::Call '*$3(i.r4,i.r5,i.r6,i.r7)'
  IntOp $6 $6 - $4
  IntOp $7 $7 - $5
  System::Call 'user32::SetWindowPos(p$R1,p0,i$4,i$5,i$6,i$7,i0x14)'

  System::Call 'user32::GetWindowRect(p$R2,@r3)'
  System::Call 'user32::MapWindowPoints(p0,p$HWNDPARENT,pr3,i2)'
  System::Call '*$3(i.r4,i.r5,i.r6,i.r7)'
  IntOp $6 $6 - $4
  IntOp $7 $7 - $5
  System::Call 'user32::SetWindowPos(p$R0,p0,i$4,i$5,i$6,i$7,i0x14)'

  SendMessage $R0 ${WM_SETTEXT} 0 "STR:完成"
  ShowWindow $R0 ${SW_SHOW}
  EnableWindow $R0 1
  SendMessage $R1 ${WM_SETTEXT} 0 "STR:打开"
  ShowWindow $R1 ${SW_SHOW}
  EnableWindow $R1 1
  ShowWindow $R2 ${SW_HIDE}
  ${NSD_OnBack} FinishPageRequestOpen
  SendMessage $HWNDPARENT ${WM_NEXTDLGCTL} $R0 1

  nsDialogs::Show
FunctionEnd

Function FinishPageRequestOpen
  StrCpy $LaunchAfterFinish 1
  GetDlgItem $0 $HWNDPARENT 1
  System::Call 'user32::PostMessage(p$HWNDPARENT,i${WM_COMMAND},p1,p$0)'
  Abort
FunctionEnd

Function FinishPageLeave
  StrCmp $LaunchAfterFinish 1 0 done
  !ifdef TEST_MODE
    FileOpen $0 "$INSTDIR\open-button.clicked" w
    FileWrite $0 "clicked"
    FileClose $0
  !else
    Exec '"$INSTDIR\${APP_EXECUTABLE}"'
  !endif
done:
FunctionEnd

Section "Uninstall"
  SetShellVarContext current

  !ifndef TEST_MODE
    !insertmacro CloseRunningZmusic
    Delete "$DESKTOP\Zmusic.lnk"
    Delete "$SMPROGRAMS\Zmusic\Zmusic.lnk"
    Delete "$SMPROGRAMS\Zmusic\卸载 Zmusic.lnk"
    RMDir "$SMPROGRAMS\Zmusic"
    !insertmacro UnregisterAudioExtension ".mp3"
    !insertmacro UnregisterAudioExtension ".flac"
    !insertmacro UnregisterAudioExtension ".ape"
    !insertmacro UnregisterAudioExtension ".m4a"
    !insertmacro UnregisterAudioExtension ".ogg"
    !insertmacro UnregisterAudioExtension ".opus"
    !insertmacro UnregisterAudioExtension ".wav"
    !insertmacro UnregisterAudioExtension ".aif"
    !insertmacro UnregisterAudioExtension ".aiff"
    !insertmacro UnregisterAudioExtension ".aifc"
    DeleteRegKey HKCU "Software\Classes\${FILE_ASSOC_PROGID}"
    DeleteRegKey HKCU "Software\Classes\Applications\${APP_EXECUTABLE}"
    DeleteRegValue HKCU "Software\RegisteredApplications" "Zmusic"
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" \
      "Zmusic"
    DeleteRegKey HKCU "${APP_CAPABILITIES_KEY}"
    DeleteRegKey /ifempty HKCU "Software\Zmusic"
    DeleteRegKey HKCU "${UNINSTALL_KEY}"
    System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
  !endif

  DetailPrint "正在删除 Zmusic 程序文件..."
  RMDir /r "$INSTDIR\data"
  RMDir /r "$INSTDIR\CMakeFiles"
  Delete "$INSTDIR\*.dll"
  Delete "$INSTDIR\${APP_EXECUTABLE}"
  Delete "$INSTDIR\*.ico"
  Delete "$INSTDIR\cmake_install.cmake"
  Delete "$INSTDIR\${INSTALL_MARKER}"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  DetailPrint "userdata 用户数据已保留。"
SectionEnd
