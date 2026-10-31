# TEST_REPORT.md — Computer Activity Logger v0.6.0

تقرير اختبار شامل. كل الأرقام أدناه **ناتجة عن تنفيذ فعلي** لـ `tests/e2e_plan.sh` (يشغّل `./main.sh` الحقيقي بتطبيقات تجريبية حقيقية في sandbox مؤقت). لا شيء هنا مكتوب من التخمين؛ وما لم يُنفَّذ مذكور صراحة في «ما لم يُختبر».

## البيئة

| البند | القيمة |
|---|---|
| النظام | Ubuntu 24.04.5 LTS (حاوية سحابية) |
| النواة | Linux 6.18.44 |
| Bash | 5.2.21 |
| المستخدم | `root` داخل الحاوية (uid 0) — البرنامج نفسه لا يحتاج root؛ اختبارات الخدمة (`test_service.sh`) تعمل بمستخدم عادي |
| systemd كـ PID 1 | **لا** (حاوية) — اختبارات الخدمة تستخدم `systemd --user` حقيقيًا داخل مساحة أسماء مستقلة |
| الفاصل | `INTERVAL_SEC=1`, `MIN_DURATION_SEC=1` (إلا في TC-20 حيث جُرّب 1 و5) |

## طريقة التشغيل

```bash
bash tests/e2e_plan.sh        # خطة الحالات العشرين (≈ 4 دقائق)
bash tests/run_all.sh         # كل المجموعات الآلية
```

التطبيقات التجريبية نسخٌ من الملف التنفيذي `sleep` بأسماء `calapp_a … calapp_f` (ليظهر كل منها باسم مستقل)، وأسماء `=evil` و`a b` لاختبار حماية الصيغ والاقتباس.

## ملخص النتائج

| ID | Test | Result | Actual result |
|---|---|---|---|
| TC-01 | First run | **PASS** | start without consent: rc=1, no files created=yes; after consent: daemon pid=7310, files created, BOM=efbbbf, modes dir/sessions/processes='700 600 600' |
| TC-02 | Username is recorded | **PASS** | row: 20261031T192811Z-7310-294b,"root",0,2026-10-31,19:28:11,,,,ACTIVE |
| TC-03 | Session start recorded | **PASS** | rows=1 id=20261031T192811Z-7310-294b status=ACTIVE login=2026-10-31 19:28:11 UTC (age 3 s); logout='' |
| TC-04 | A new application is started | **PASS** | pid 7403 alive=yes |
| TC-05 | New process is detected | **PASS** | detected after 1.6 s; listed 1x by 'processes --running' |
| TC-07 | The application is closed | **PASS** | alive=no |
| TC-08 | End of process is detected | **PASS** | row: 20261031T192811Z-7310-294b,7403,"calapp_a","root",2026-10-31 19:28:15,2026-10-31 19:28:20,5,COMPLETED |
| TC-06 | Process start time recorded | **PASS** | launch=1793474894 recorded=1793474895 (diff 1 s) [2026-10-31 19:28:15] |
| TC-09 | Process end time recorded | **PASS** | kill=1793474898 recorded=1793474900 (diff 2 s) [2026-10-31 19:28:20] |
| TC-10 | Process duration | **PASS** | real=4 s recorded=5 s end-start=5 s |
| TC-11 | Several applications at the same time | **PASS** | missing=0 off-by>2s=0 distinct_pids=5; calapp_b:3s(real 3s) calapp_c:4s(real 5s) calapp_d:6s(real 7s) calapp_e:8s(real 9s) calapp_f:10s(real 11s)  |
| TC-12 | Short-lived processes | **PASS** | 0.1 s processes recorded: 2/20 (longest recorded duration 1 s, real 0.1 s); 3 s process row: yes; daemon alive=yes; processes --check rc=0 |
| TC-13 | Process killed by force (SIGKILL) | **PASS** | row: 20261031T192811Z-7310-294b,7752,"calapp_c","root",2026-10-31 19:28:45,2026-10-31 19:28:46,1,COMPLETED; still tracked=0; daemon alive=yes |
| TC-14 | Restarting the monitor | **PASS** | rows for pid 7807: 2 [statuses: SESSION_END COMPLETED ]; session rows now 3 (was 1); statuses: COMPLETED CRASHED ACTIVE  |
| TC-15 | Machine stop and reboot | **EMULATED** | previous session status=POWER_LOSS; ACTIVE rows now=1. NOT a real reboot: this container cannot be rebooted, and no systemd/logind boot sequence was exercised |
| TC-16 | Incomplete records | **PASS** | orphaned app row: 20261031T192907Z-8234-15c3,8326,"calapp_f","root",2026-10-31 19:29:11,2026-10-31 19:29:15,4,RECOVERED; ACTIVE rows=1; sessions: COMPLETED CRASHED COMPLETED POWER_LOSS CRASHED ACTIVE ; stats mentions recovered/incomplete: 3 line(s) |
| TC-17 | Reports are created | **PASS** | report rc=0 verify rc=0 files=[application_activity_report.csv report_manifest.csv session_report.csv usage_summary_report.csv ] first-session-rows-in-report=1 |
| TC-18 | CSV files are valid | **PASS** | sessions --check rc=0, processes --check rc=0, columns/row:      67 8 ; '=evil' row: 20261031T192917Z-8372-7447,8637,"'=evil","root",2026-10-31 19:29:21,2026-10-31 19:29:25,4,COMPLETED; 'a b' row: 20261031T192917Z-8372-7447,8638,"a b","root",2026-10-31 19:29:21,2026-10-31 19:29:25,4,COMPLETED; report CRLF:       4 ok  |
| TC-19 | No duplicated events | **PASS** | process rows=67 duplicate keys=0; duplicated session ids=0 |
| TC-20 | CPU and RAM usage | **PASS** | INTERVAL_SEC=1: CPU 2.80% RSS 6 MB (peak 6 MB); INTERVAL_SEC=5: CPU 0.70% RSS 6 MB (peak 6 MB); 143 processes owned by the user |

**20 حالة: 19 PASS، 1 EMULATED (TC-15)، 0 FAIL، 0 NOT-TESTED** في آخر تشغيل. (EMULATED = نُفِّذ بمحاكاة وليس بالحدث الحقيقي، انظر أدناه.)

## تفاصيل كل حالة (الهدف / الخطوات / المتوقع / الفعلي / النتيجة)

#### TC-01 — First run

- **Steps:** 1) ./main.sh start with no consent 2) consent --accept 3) ./main.sh start
- **Expected:** Refused without consent (non-zero, no data files); with consent the daemon runs and creates sessions.csv + processes.csv (UTF-8 BOM, dir 700, files 600)
- **Actual:** start without consent: rc=1, no files created=yes; after consent: daemon pid=7310, files created, BOM=efbbbf, modes dir/sessions/processes='700 600 600'
- **Result:** **PASS**

#### TC-02 — Username is recorded

- **Steps:** Read the Username/User_ID columns of the first session row
- **Expected:** Username == 'root', User_ID == 0
- **Actual:** row: 20261031T192811Z-7310-294b,"root",0,2026-10-31,19:28:11,,,,ACTIVE
- **Result:** **PASS**

#### TC-03 — Session start recorded

- **Steps:** Start the daemon; read the ACTIVE row
- **Expected:** Exactly one row, Status ACTIVE, Login (UTC) within 30 s of now, unique non-empty Session_ID, logout columns empty
- **Actual:** rows=1 id=20261031T192811Z-7310-294b status=ACTIVE login=2026-10-31 19:28:11 UTC (age 3 s); logout=''
- **Result:** **PASS**

#### TC-04 — A new application is started

- **Steps:** Run a copy of sleep named calapp_a (pid 7403) for 120 s
- **Expected:** The process exists
- **Actual:** pid 7403 alive=yes
- **Result:** **PASS**

#### TC-05 — New process is detected

- **Steps:** Poll state/active.tsv and './main.sh processes --running' after launch
- **Expected:** Appears in the tracked list within 1 scan interval + margin (<= 4 s), exactly once
- **Actual:** detected after 1.6 s; listed 1x by 'processes --running'
- **Result:** **PASS**

#### TC-07 — The application is closed

- **Steps:** kill -TERM the application (pid 7403)
- **Expected:** Process gone
- **Actual:** alive=no
- **Result:** **PASS**

#### TC-08 — End of process is detected

- **Steps:** Wait for the row in processes.csv
- **Expected:** A COMPLETED row for pid 7403 appears within 4 s
- **Actual:** row: 20261031T192811Z-7310-294b,7403,"calapp_a","root",2026-10-31 19:28:15,2026-10-31 19:28:20,5,COMPLETED
- **Result:** **PASS**

#### TC-06 — Process start time recorded

- **Steps:** Compare Start_Time (UTC) with the epoch taken just before launch
- **Expected:** |Start_Time - launch| <= 2 s (documented precision +-1 s)
- **Actual:** launch=1793474894 recorded=1793474895 (diff 1 s) [2026-10-31 19:28:15]
- **Result:** **PASS**

#### TC-09 — Process end time recorded

- **Steps:** Compare End_Time with the epoch taken just before kill
- **Expected:** 0 <= End_Time - kill <= 3 s (End is the DETECTION time)
- **Actual:** kill=1793474898 recorded=1793474900 (diff 2 s) [2026-10-31 19:28:20]
- **Result:** **PASS**

#### TC-10 — Process duration

- **Steps:** Duration_Seconds vs (kill - launch) and vs End - Start
- **Expected:** |Duration - real lifetime| <= 2 s; Duration == End - Start (+-1 s)
- **Actual:** real=4 s recorded=5 s end-start=5 s
- **Result:** **PASS**

#### TC-11 — Several applications at the same time

- **Steps:** Start 5 apps with lifetimes 3,5,7,9,11 s concurrently
- **Expected:** 5 separate rows (distinct PIDs), each duration within 2 s of its own lifetime (not merged or summed)
- **Actual:** missing=0 off-by>2s=0 distinct_pids=5; calapp_b:3s(real 3s) calapp_c:4s(real 5s) calapp_d:6s(real 7s) calapp_e:8s(real 9s) calapp_f:10s(real 11s) 
- **Result:** **PASS**

#### TC-12 — Short-lived processes

- **Steps:** Run 20 processes of 0.1 s (INTERVAL_SEC=1, MIN_DURATION_SEC=1) then one of 3 s
- **Expected:** Daemon stays alive, files valid. A sub-interval process is only seen if a scan lands inside its life (probability ~ lifetime/interval = ~10 %, so ~2 of 20 expected); when seen, its duration is quantised to the scan interval (<= 2 s) — a documented limitation, not an error. The 3 s process is recorded
- **Actual:** 0.1 s processes recorded: 2/20 (longest recorded duration 1 s, real 0.1 s); 3 s process row: yes; daemon alive=yes; processes --check rc=0
- **Result:** **PASS**

#### TC-13 — Process killed by force (SIGKILL)

- **Steps:** kill -9 a tracked application
- **Expected:** Detected like any end: one COMPLETED row, no longer tracked, daemon unaffected (the reason of death cannot be known to an unprivileged monitor)
- **Actual:** row: 20261031T192811Z-7310-294b,7752,"calapp_c","root",2026-10-31 19:28:45,2026-10-31 19:28:46,1,COMPLETED; still tracked=0; daemon alive=yes
- **Result:** **PASS**

#### TC-14 — Restarting the monitor

- **Steps:** App calapp_d running; (a) ./main.sh stop + start; (b) kill -9 daemon + start; then close the app
- **Expected:** (a) stop writes the app as SESSION_END; after restart it is found running (never a new 'start' with a fake time); (b) recovery re-attaches survivors with the ORIGINAL record; no duplicates of one (PID,start) in one session; old sessions closed (COMPLETED / CRASHED), exactly one ACTIVE
- **Actual:** rows for pid 7807: 2 [statuses: SESSION_END COMPLETED ]; session rows now 3 (was 1); statuses: COMPLETED CRASHED ACTIVE 
- **Result:** **PASS**

#### TC-15 — Machine stop and reboot

- **Steps:** EMULATED: kill -9 the daemon and its tracked app together, then start with a different kernel boot_id (CAL_BOOT_ID_FILE hook)
- **Expected:** Previous session marked POWER_LOSS (end estimated from the last heartbeat); a new ACTIVE session opens; no ACTIVE zombie
- **Actual:** previous session status=POWER_LOSS; ACTIVE rows now=1. NOT a real reboot: this container cannot be rebooted, and no systemd/logind boot sequence was exercised
- **Result:** **EMULATED**

#### TC-16 — Incomplete records

- **Steps:** App tracked, daemon kill -9, app dies unobserved, daemon restarted; run stats
- **Expected:** App row closed as RECOVERED (estimated end, not COMPLETED); crashed session CRASHED/POWER_LOSS; only one ACTIVE; stats runs, counts them separately, never as normal completions
- **Actual:** orphaned app row: 20261031T192907Z-8234-15c3,8326,"calapp_f","root",2026-10-31 19:29:11,2026-10-31 19:29:15,4,RECOVERED; ACTIVE rows=1; sessions: COMPLETED CRASHED COMPLETED POWER_LOSS CRASHED ACTIVE ; stats mentions recovered/incomplete: 3 line(s)
- **Result:** **PASS**

#### TC-17 — Reports are created

- **Steps:** ./main.sh report period --name e2e; ./main.sh report verify
- **Expected:** rc 0; session_report, application_activity_report, usage_summary_report + manifest exist; verify passes; the first session appears in the session report
- **Actual:** report rc=0 verify rc=0 files=[application_activity_report.csv report_manifest.csv session_report.csv usage_summary_report.csv ] first-session-rows-in-report=1
- **Result:** **PASS**

#### TC-18 — CSV files are valid

- **Steps:** sessions --check, processes --check, report verify; apps named '=evil' and 'a b' to test formula-injection guard and quoting; constant column count
- **Expected:** All checks rc 0; a name starting with '=' is neutralised (apostrophe) in the CSV; a name with a space is quoted; every processes row has the same number of columns; reports use CRLF
- **Actual:** sessions --check rc=0, processes --check rc=0, columns/row:      67 8 ; '=evil' row: 20261031T192917Z-8372-7447,8637,"'=evil","root",2026-10-31 19:29:21,2026-10-31 19:29:25,4,COMPLETED; 'a b' row: 20261031T192917Z-8372-7447,8638,"a b","root",2026-10-31 19:29:21,2026-10-31 19:29:25,4,COMPLETED; report CRLF:       4 ok 
- **Result:** **PASS**

#### TC-19 — No duplicated events

- **Steps:** Whole run incl. 2 clean restarts, 3 kill -9 and a power-loss emulation: look for repeated (Session_ID,PID,Start_Time) keys and Session_IDs
- **Expected:** 0 duplicated process keys, 0 duplicated Session_IDs
- **Actual:** process rows=67 duplicate keys=0; duplicated session ids=0
- **Result:** **PASS**

#### TC-20 — CPU and RAM usage

- **Steps:** Daemon with ~143 user processes (60 extra test apps running); measure CPU (utime+stime incl. waited children: ps/awk) and RSS over 30 s at INTERVAL_SEC=1 and 5
- **Expected:** INTERVAL_SEC=1: CPU < 5 % and RSS < 50 MB; INTERVAL_SEC=5: CPU < 2 %
- **Actual:** INTERVAL_SEC=1: CPU 2.80% RSS 6 MB (peak 6 MB); INTERVAL_SEC=5: CPU 0.70% RSS 6 MB (peak 6 MB); 143 processes owned by the user
- **Result:** **PASS**

## ملاحظات على النتائج (للقراءة النقدية)

- **TC-06/TC-09** (فرق ثانية واحدة): متوقع ومعلن في التصميم. `Start_Time` مشتق من «الآن − etimes» (دقة ثانية)، و`End_Time` هو وقت **اكتشاف** الانتهاء وليس لحظته.
- **TC-11**: كل مدة جاءت أقل من العمر الفعلي بثانية في بعض الحالات (مثلاً 4 مقابل 5)؛ مقبول ضمن ±2 ثانية، لكنه يؤكد أن القياس بالاستعلام الدوري ليس دقيقًا بالثانية.
- **TC-12 (حد معروف، وليس عيبًا مصلحًا):** عملية عمرها 0.1 ثانية لا تُرى إلا إن وقع فحصٌ داخل عمرها (احتمال ≈ 10%)؛ ولهذا سُجّلت 2 من 20 (وهو ما تتوقعه الاحتمالات)، وحين تُرى **تُسجَّل بمدة 1 ثانية لا 0.1** (تكميم إلى فاصل الفحص). أي أن مدد العمليات القصيرة جدًا **مبالغ فيها** حتى فاصل فحص واحد. خفض `INTERVAL_SEC` يحسّن لكن لا يلغي ذلك. العملية ذات الثلاث ثوانٍ سُجّلت.
- **TC-13**: لا يمكن لمستخدم عادي معرفة أن العملية قُتلت بالقوة؛ تُسجَّل `COMPLETED` كأي انتهاء. هذا سلوك موثّق.
- **TC-14**: تحققنا من: صفان للعملية (`SESSION_END` عند الإيقاف النظيف ثم `COMPLETED` بعد إعادة التشغيل)، وجلسات `COMPLETED, CRASHED, ACTIVE` وجلسة نشطة واحدة. لم يتحقق السكربت آليًا من علم `pre=yes` في `process_details.csv`؛ ذلك مغطى باختبارات `test_processes.sh` (175 فحصًا).
- **TC-20**: عند فاصل 1 ثانية و143 عملية للمستخدم: ‏CPU ≈ 2.9% (يشمل `ps`/`awk` الفرعيين) وذاكرة 6 MB؛ عند 5 ثوانٍ: ‏0.6%. يطابق ما في README. الحمل يزداد مع عدد العمليات.

## الأخطاء التي ظهرت أثناء هذه الجولة وإصلاحها

كل إخفاق ظهر في الجولات الأولى كان **خطأً في السكربت/التوقع وليس في المنتج** (ولم يُكتشف عيب جديد في المنتج بهذه الخطة)، وهذه قائمته كاملة:

| الاكتشاف | السبب | الإصلاح | إعادة الاختبار |
|---|---|---|---|
| TC-12 أخفق: سُجّلت 2/20 عملية قصيرة | توقعي «لا شيء يُسجَّل» كان خاطئًا؛ العملية القصيرة تُلتقط احتماليًا وتُكمَّم مدتها | صُحّح التوقع ليصف السلوك الحقيقي (وأُضيف فحص أن أطول مدة ≤ 2 ث) | PASS |
| TC-16 أخفق: لا صف للعملية اليتيمة | السكربت قتل المراقب بعد أقل من `MIN_DURATION_SEC` من اكتشاف العملية فأُسقطت بالتصميم، وأعاد التشغيل بمعرّف إقلاع مختلف | انتظار 4 ث قبل القتل وإبقاء معرّف الإقلاع نفسه | PASS |
| TC-12 (ثانيةً) أخفق: لا صف للعملية 3 ث | `disown` في السكربت جعل `wait` يعود فورًا فقرأ النتيجة قبل انتهاء العملية | استبدال `wait` بـ `sleep 6` | PASS |

وأخطاء وجدتها مجموعات الاختبار الآلية في هذه المرحلة (التشغيل التلقائي) وأُصلحت: `$$` في مسار التنفيذ يبقى حرفيًا فلا يجب تضعيفه؛ `Documentation=file://` يرفض المسافات (حُذف)؛ اختبار `test_reports.sh` كان يتوقع `ExecStart` غير مقتبس؛ سكربت اختبار أرسل الإشارة لصدفة فرعية فسرّب مسجِّلًا؛ `install.sh` لم يعرض Usage. كلها موثّقة في `docs/DESIGN.md` §21.

## المجموعات الآلية الأخرى (آخر تشغيل كامل)

| المجموعة | الفحوص | النتيجة |
|---|---|---|
| `test_sessions.sh` | 75 | ناجحة |
| `test_processes.sh` | 175 | ناجحة |
| `test_activity.sh` | 127 | ناجحة |
| `test_reports.sh` | 213 | ناجحة (بعد تصحيح توقع `ExecStart` المقتبس) |
| `test_service.sh` | 168 | ناجحة، على `systemd --user` 255 حقيقي |
| `smoke.sh` | — | ناجح |
| `shellcheck` | — | **لم يُشغَّل** (غير مثبّت في الحاوية)؛ نجح `bash -n` فقط |

## ما لم يُختبر (صراحةً)

1. **إعادة إقلاع حقيقية (TC-15):** الحاوية لا يمكن إعادة إقلاعها. المنفَّذ **محاكاة**: `kill -9` للمراقب وتطبيقه معًا ثم تشغيل بمعرّف إقلاع مختلف (`CAL_BOOT_ID_FILE`). تحقق منها فعليًا مسار التعافي (`POWER_LOSS`)، ولم يُختبر تسلسل إقلاع systemd/logind الحقيقي.
2. **تسجيل دخول رسمي (logind/PAM) وجلسة سطح مكتب:** غير متاحين هنا. «الدخول» مُحاكى بإعادة تشغيل مدير `systemd --user` (انظر `test_service.sh` B12). لم تُختبر تطبيقات رسومية (متصفح، محرر…) بل ملفات تنفيذية تجريبية؛ تصنيف «تطبيق/خلفية» بناءً على ملفات `.desktop` لم يُجرَّب على سطح مكتب Ubuntu حقيقي.
3. **Excel الفعلي:** لم يتوفر. تُفتح الملفات في LibreOffice في `test_reports.sh` (إن كان مثبّتًا) ويُفحص CRLF/BOM/الاقتباس.
4. **تشغيل غير root على Ubuntu حقيقية لـ TC-01…20:** نُفِّذت بمستخدم `root` داخل الحاوية؛ اختبارات الخدمة وحدها شغّلت المراقب بمستخدم عادي.
5. **قياس طويل الأمد:** TC-20 قاس 30 ثانية لكل فاصل، لا ساعات؛ لا تسرّب ذاكرة مُثبَت أو منفي على المدى الطويل.
6. **اختبار الطفرات** (تعطيل ميزة والتأكد أن الاختبار يفشل) نُفِّذ لمجموعة الخدمة (حذف `RestartPreventExitStatus` أسقط 3 فحوص)، **ولم يُنفَّذ** لسكربت `e2e_plan.sh` نفسه.
