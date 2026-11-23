# Telegram зі зміною голосу → TestFlight

Це офіційний Telegram для iOS з однією доданою функцією: кнопкою **🎭**, яка висить поверх
будь-якого екрана. Натискаєш її і вибираєш голос, і він одразу застосовується до:

- **голосових повідомлень** (`ManagedAudioRecorder`)
- **кружечків** (`CameraNeo` / `CameraLegacy`, тільки для режиму кружечка)
- **дзвінків**, особистих і групових (спільний аудіопристрій дзвінків у `TgVoipWebrtc`)

Голоси: Мій голос, Бурундук, Низький, Робот, Жіночий, Чоловічий, Прибулець, Луна, Рація,
Монстр, Дитина, Печера. Кнопку можна перетягувати й зменшувати. Вибраний голос
запам'ятовується.

Код: `submodules/VoiceChangerCore` (обробка звуку, C) і `submodules/VoiceChangerUI` (кнопка, Swift).

Акаунти й чати ті самі: це повноцінний клієнт Telegram, ти просто входиш під своїм номером.

---

## Що зробити один раз

### 1. Ключ App Store Connect API
appstoreconnect.apple.com → **Users and Access** → **Integrations** → **App Store Connect API**
→ **Team Keys** → **+**, роль **Admin**. Завантаж файл `AuthKey_XXXXXXX.p8` (його можна
завантажити тільки один раз) і запиши **Key ID** та **Issuer ID**.

### 2. Bundle ID
Придумай ідентифікатор, наприклад `com.tviyeimya.voicetg`.

### 3. Ідентифікатори й сертифікат (скрипт робить це сам)
У PowerShell, у теці репозиторію:

```powershell
$env:ASC_KEY_ID="XXXXXXX"; $env:ASC_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"; $env:ASC_KEY_PATH="C:\шлях\AuthKey_XXXXXXX.p8"
```
```powershell
python tools/testflight/asc.py ensure-ids --bundle-id com.tviyeimya.voicetg
```
```powershell
python tools/testflight/asc.py init-cert --out $HOME\voicetg-signing
```

Тека `voicetg-signing` міститиме `distribution_key.pem` і `distribution.cer`. Це секрет:
нікому не надсилай і не клади в репозиторій.

### 4. App Group (вручну, бо Apple не дає це зробити через API)
developer.apple.com → **Certificates, Identifiers & Profiles** → **Identifiers** → фільтр
**App Groups** → **+** → `group.com.tviyeimya.voicetg`.

Потім відкрий кожен із 7 ідентифікаторів (скрипт виводить список) → **App Groups** →
**Configure** → постав галочку біля цієї групи → **Save**.

### 5. Застосунок в App Store Connect
**Apps** → **+** → **New App** → iOS, назва будь-яка, але не «Telegram» (ця зайнята), Bundle
ID вибери зі списку, SKU будь-який.

### 6. Репозиторій на GitHub
Створи репозиторій (**публічний**: тоді хмарний Mac безкоштовний; секрети при цьому
лишаються прихованими) і залий туди цей код.

**Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Значення |
|---|---|
| `APPLE_TEAM_ID` | Team ID (developer.apple.com → Membership) |
| `BUNDLE_ID` | `com.tviyeimya.voicetg` |
| `TG_API_ID` | api_id з my.telegram.org |
| `TG_API_HASH` | api_hash з my.telegram.org |
| `ASC_KEY_ID` | Key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | весь вміст файлу `.p8` |
| `DIST_KEY_PEM` | весь вміст `distribution_key.pem` |
| `DIST_CERT_B64` | результат команди нижче |

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$HOME\voicetg-signing\distribution.cer")) | Set-Clipboard
```

## Кожна нова збірка
GitHub → **Actions** → **TestFlight** → **Run workflow**. Перша збірка триває кілька годин,
наступні йдуть швидше завдяки кешу. Потім App Store Connect → **TestFlight** → додай себе в
**Internal Testing**, і на iPhone застосунок з'явиться в програмі TestFlight.

## Якщо щось не так
- **«is not in the App Group»**: крок 4 не завершено для якогось ідентифікатора.
- **Нестача місця на диску / тайм-аут**: у `.github/workflows/testflight.yml` заміни
  `runs-on: xcode-27` на більший платний runner (`xcode-27-xlarge`).
- **Немає потрібного Xcode**: workflow бере найновіший встановлений і пише попередження.
  Якщо збірка падає саме через версію, вкажи потрібну версію в кроці «Select Xcode».
