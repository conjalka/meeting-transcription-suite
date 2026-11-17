Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & _
    WshShell.ExpandEnvironmentStrings("%USERPROFILE%") & _
    "\Documents\TranscriptionSuite\scripts\Start-TranscriptionSuite.ps1""", 0, False
