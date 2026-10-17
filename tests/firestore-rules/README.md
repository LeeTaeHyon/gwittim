# Firestore 보안 규칙 테스트

`firestore.rules`를 Firestore Emulator에서 검증합니다. 클라우드 프로젝트가 없어도 됩니다(`demo-gwittim`).

```bash
cd tests/firestore-rules
npm install
npm test
```

- 필요: Node 20+, Java 11+ (에뮬레이터 실행용)
- Windows에서는 `emulators:exec`이 끝난 뒤 에뮬레이터 Java 프로세스가 8080 포트에 남을 수 있습니다. 다시 실행할 때 "port taken"이 나오면 PowerShell에서 정리하세요:

```powershell
Get-NetTCPConnection -LocalPort 8080 -State Listen | % { Stop-Process -Id $_.OwningProcess }
```
