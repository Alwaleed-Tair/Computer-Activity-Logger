# TEST_REPORT.md — Computer Activity Logger v0.6.1

تقرير الاختبار النهائي. **كل رقم هنا ناتج عن تنفيذ فعلي** في هذه البيئة (الأرقام المنقولة من تشغيلات سابقة مُنسوبة إلى مصدرها). ما لم يُختبر مذكور صراحةً في القسم 6، ولا تُعدّ أي ميزة مكتملة إلا إن ظهر اختبارها هنا.

## 1. البيئة

| البند | القيمة |
|---|---|
| النظام | Ubuntu 24.04.5 LTS (حاوية سحابية، **ليست جهازًا فعليًا**) |
| النواة / Bash | Linux 6.18.44 / Bash 5.2.21 |
| المستخدم | `root` داخل الحاوية (اختبارات الخدمة تعمل بمستخدم مؤقت غير root) |
| systemd كـ PID 1 | لا — مدير `systemd --user` (الإصدار 255) يُشغَّل داخل مساحة أسماء مستقلة (`tests/usermgr.sh`) |
| shellcheck | غير مثبّت ولم يُسمح بتثبيته → لم يُشغَّل؛ نُفِّذ `bash -n` على كل الملفات |
| LibreOffice | استُخدم في `test_reports.sh` لفتح التقارير (إن كان موجودًا)؛ Microsoft Excel نفسه غير متاح |

## 2. طبقات الاختبار وآخر نتائجها (تشغيل `bash tests/run_all.sh` بعد آخر تعديل على الشيفرة)

| الطبقة | الملف | الفحوص | النتيجة |
|---|---|---|---|
| مسجّل الجلسات | `tests/test_sessions.sh` | 75 | 0 إخفاق |
| مراقب العمليات | `tests/test_processes.sh` | 175 | 0 إخفاق |
| محلل النشاط | `tests/test_activity.sh` | 127 | 0 إخفاق (بعد تعديل التسامح، انظر §5-ي) — أُعيد تشغيله 3 مرات متتالية: 127/0 في كل مرة |
| مولّد التقارير | `tests/test_reports.sh` | 213 | 0 إخفاق |
| الخدمة التلقائية (مدير systemd حقيقي) | `tests/test_service.sh` | 168 | 0 إخفاق |
| انحدار المراجعة | `tests/test_review.sh` | 50 | 0 إخفاق (13 من أول 36 فحصًا تفشل على الشيفرة القديمة — تأكيد أن الاختبار قادر على الفشل) |
| smoke | `tests/smoke.sh` | 17 | كلها ناجحة |
| فحص الصياغة | `bash -n` | كل ملفات `.sh` | ناجح |
| خطة الحالات العشرين | `tests/e2e_plan.sh` | 20 حالة | 19 PASS + 1 EMULATED + 0 FAIL |
| القبول من الصفر | `tests/final_check.sh` | 61 | 0 إخفاق (بعد إصلاحين، §7) |

ملاحظة أمانة: في التشغيل الكامل (`run_all.sh`) أخفق فحص واحد في `test_activity.sh` (`rc=1`)، وكان قبل تعديل التسامح؛ سبب الإخفاق والإصلاح في §5-ي. باقي الطبقات نجحت في ذلك التشغيل نفسه؛ ولم أُعد تشغيل `run_all.sh` بكامله بعد تعديل `test_activity.sh` بل أعدت تشغيل ذلك الملف وحده (3 مرات).

## 3. خطة الحالات العشرين (تنفيذ فعلي بتطبيقات تجريبية)

التطبيقات التجريبية نسخٌ من الملف التنفيذي `sleep` بأسماء `calapp_a…f` (و`=evil` و`a b`). الإعدادات: `INTERVAL_SEC=1`، `MIN_DURATION_SEC=1`. السكربت `tests/e2e_plan.sh` يطبع لكل حالة النتيجة الفعلية، وهذا جدولها من آخر تشغيل:

| ID | Test | Result | Actual result |
|---|---|---|---|
| TC-01 | First run | **PASS** | start without consent: rc=1, no files created=yes; after consent: daemon pid=26567, files created, BOM=efbbbf, modes dir/sessions/processes='700 600 600' |
| TC-02 | Username is recorded | **PASS** | row: 20261031T195210Z-26567-1350,"root",0,2026-10-31,19:52:10,,,,ACTIVE |
| TC-03 | Session start recorded | **PASS** | rows=1 id=20261031T195210Z-26567-1350 status=ACTIVE login=2026-10-31 19:52:10 UTC (age 2 s); logout='' |
| TC-04 | A new application is started | **PASS** | pid 26661 alive=yes |
| TC-05 | New process is detected | **PASS** | detected after 1.4 s; listed 1x by 'processes --running' |
| TC-07 | The application is closed | **PASS** | alive=no |
| TC-08 | End of process is detected | **PASS** | row: 20261031T195210Z-26567-1350,26661,"calapp_a","root",2026-10-31 19:52:13,2026-10-31 19:52:16,3,COMPLETED |
| TC-06 | Process start time recorded | **PASS** | launch=1793476332 recorded=1793476333 (diff 1 s) [2026-10-31 19:52:13] |
| TC-09 | Process end time recorded | **PASS** | kill=1793476336 recorded=1793476336 (diff 0 s) [2026-10-31 19:52:16] |
| TC-10 | Process duration | **PASS** | real=4 s recorded=3 s end-start=3 s |
| TC-11 | Several applications at the same time | **PASS** | missing=0 off-by>2s=0 distinct_pids=5; calapp_b:3s(real 3s) calapp_c:6s(real 5s) calapp_d:8s(real 7s) calapp_e:10s(real 9s) calapp_f:12s(real 11s)  |
| TC-12 | Short-lived processes | **PASS** | 0.1 s processes recorded: 2/20 (longest recorded duration 1 s, real 0.1 s); 3 s process row: yes; daemon alive=yes; processes --check rc=0 |
| TC-13 | Process killed by force (SIGKILL) | **PASS** | row: 20261031T195210Z-26567-1350,26988,"calapp_c","root",2026-10-31 19:52:42,2026-10-31 19:52:43,1,COMPLETED; still tracked=0; daemon alive=yes |
| TC-14 | Restarting the monitor | **PASS** | rows for pid 27039: 2 [statuses: SESSION_END COMPLETED ]; session rows now 3 (was 1); statuses: COMPLETED CRASHED ACTIVE  |
| TC-15 | Machine stop and reboot | **EMULATED** | previous session status=POWER_LOSS; ACTIVE rows now=1. NOT a real reboot: this container cannot be rebooted, and no systemd/logind boot sequence was exercised |
| TC-16 | Incomplete records | **PASS** | orphaned app row: 20261031T195301Z-27491-5b7a,27590,"calapp_f","root",2026-10-31 19:53:04,2026-10-31 19:53:08,4,RECOVERED; ACTIVE rows=1; sessions: COMPLETED CRASHED COMPLETED POWER_LOSS CRASHED ACTIVE ; stats mentions recovered/incomplete: 3 line(s) |
| TC-17 | Reports are created | **PASS** | report rc=0 verify rc=0 files=[application_activity_report.csv report_manifest.csv session_report.csv usage_summary_report.csv ] first-session-rows-in-report=1 |
| TC-18 | CSV files are valid | **PASS** | sessions --check rc=0, processes --check rc=0, columns/row:      58 8 ; '=evil' row: 20261031T195310Z-27635-1e2c,27909,"'=evil","root",2026-10-31 19:53:14,2026-10-31 19:53:18,4,COMPLETED; 'a b' row: 20261031T195310Z-27635-1e2c,27910,"a b","root",2026-10-31 19:53:14,2026-10-31 19:53:18,4,COMPLETED; report CRLF:       4 ok  |
| TC-19 | No duplicated events | **PASS** | process rows=58 duplicate keys=0; duplicated session ids=0 |
| TC-20 | CPU and RAM usage | **PASS** | INTERVAL_SEC=1: CPU 3.17% RSS 6 MB (peak 6 MB); INTERVAL_SEC=5: CPU 0.70% RSS 6 MB (peak 6 MB); 145 processes owned by the user |

### تفاصيل كل حالة (الهدف / الخطوات / المتوقع / الفعلي / النتيجة)

#### TC-01 — First run

- **Steps:** 1) ./main.sh start with no consent 2) consent --accept 3) ./main.sh start
- **Expected:** Refused without consent (non-zero, no data files); with consent the daemon runs and creates sessions.csv + processes.csv (UTF-8 BOM, dir 700, files 600)
- **Actual:** start without consent: rc=1, no files created=yes; after consent: daemon pid=26567, files created, BOM=efbbbf, modes dir/sessions/processes='700 600 600'
- **Result:** **PASS**

#### TC-02 — Username is recorded

- **Steps:** Read the Username/User_ID columns of the first session row
- **Expected:** Username == 'root', User_ID == 0
- **Actual:** row: 20261031T195210Z-26567-1350,"root",0,2026-10-31,19:52:10,,,,ACTIVE
- **Result:** **PASS**

#### TC-03 — Session start recorded

- **Steps:** Start the daemon; read the ACTIVE row
- **Expected:** Exactly one row, Status ACTIVE, Login (UTC) within 30 s of now, unique non-empty Session_ID, logout columns empty
- **Actual:** rows=1 id=20261031T195210Z-26567-1350 status=ACTIVE login=2026-10-31 19:52:10 UTC (age 2 s); logout=''
- **Result:** **PASS**

#### TC-04 — A new application is started

- **Steps:** Run a copy of sleep named calapp_a (pid 26661) for 120 s
- **Expected:** The process exists
- **Actual:** pid 26661 alive=yes
- **Result:** **PASS**

#### TC-05 — New process is detected

- **Steps:** Poll state/active.tsv and './main.sh processes --running' after launch
- **Expected:** Appears in the tracked list within 1 scan interval + margin (<= 4 s), exactly once
- **Actual:** detected after 1.4 s; listed 1x by 'processes --running'
- **Result:** **PASS**

#### TC-07 — The application is closed

- **Steps:** kill -TERM the application (pid 26661)
- **Expected:** Process gone
- **Actual:** alive=no
- **Result:** **PASS**

#### TC-08 — End of process is detected

- **Steps:** Wait for the row in processes.csv
- **Expected:** A COMPLETED row for pid 26661 appears within 4 s
- **Actual:** row: 20261031T195210Z-26567-1350,26661,"calapp_a","root",2026-10-31 19:52:13,2026-10-31 19:52:16,3,COMPLETED
- **Result:** **PASS**

#### TC-06 — Process start time recorded

- **Steps:** Compare Start_Time (UTC) with the epoch taken just before launch
- **Expected:** |Start_Time - launch| <= 2 s (documented precision +-1 s)
- **Actual:** launch=1793476332 recorded=1793476333 (diff 1 s) [2026-10-31 19:52:13]
- **Result:** **PASS**

#### TC-09 — Process end time recorded

- **Steps:** Compare End_Time with the epoch taken just before kill
- **Expected:** 0 <= End_Time - kill <= 3 s (End is the DETECTION time)
- **Actual:** kill=1793476336 recorded=1793476336 (diff 0 s) [2026-10-31 19:52:16]
- **Result:** **PASS**

#### TC-10 — Process duration

- **Steps:** Duration_Seconds vs (kill - launch) and vs End - Start
- **Expected:** |Duration - real lifetime| <= 2 s; Duration == End - Start (+-1 s)
- **Actual:** real=4 s recorded=3 s end-start=3 s
- **Result:** **PASS**

#### TC-11 — Several applications at the same time

- **Steps:** Start 5 apps with lifetimes 3,5,7,9,11 s concurrently
- **Expected:** 5 separate rows (distinct PIDs), each duration within 2 s of its own lifetime (not merged or summed)
- **Actual:** missing=0 off-by>2s=0 distinct_pids=5; calapp_b:3s(real 3s) calapp_c:6s(real 5s) calapp_d:8s(real 7s) calapp_e:10s(real 9s) calapp_f:12s(real 11s) 
- **Result:** **PASS**

#### TC-12 — Short-lived processes

- **Steps:** Run 20 processes of 0.1 s (INTERVAL_SEC=1, MIN_DURATION_SEC=1) then one of 3 s
- **Expected:** Daemon stays alive, files valid. A sub-interval process is only seen if a scan lands inside its life (probability ~ lifetime/interval = ~10 %, so ~2 of 20 expected); when seen, its duration is quantised to the scan interval (<= 2 s) — a documented limitation, not an error. The 3 s process is recorded
- **Actual:** 0.1 s processes recorded: 2/20 (longest recorded duration 1 s, real 0.1 s); 3 s process row: yes; daemon alive=yes; processes --check rc=0
- **Result:** **PASS**

#### TC-13 — Process killed by force (SIGKILL)

- **Steps:** kill -9 a tracked application
- **Expected:** Detected like any end: one COMPLETED row, no longer tracked, daemon unaffected (the reason of death cannot be known to an unprivileged monitor)
- **Actual:** row: 20261031T195210Z-26567-1350,26988,"calapp_c","root",2026-10-31 19:52:42,2026-10-31 19:52:43,1,COMPLETED; still tracked=0; daemon alive=yes
- **Result:** **PASS**

#### TC-14 — Restarting the monitor

- **Steps:** App calapp_d running; (a) ./main.sh stop + start; (b) kill -9 daemon + start; then close the app
- **Expected:** (a) stop writes the app as SESSION_END; after restart it is found running (never a new 'start' with a fake time); (b) recovery re-attaches survivors with the ORIGINAL record; no duplicates of one (PID,start) in one session; old sessions closed (COMPLETED / CRASHED), exactly one ACTIVE
- **Actual:** rows for pid 27039: 2 [statuses: SESSION_END COMPLETED ]; session rows now 3 (was 1); statuses: COMPLETED CRASHED ACTIVE 
- **Result:** **PASS**

#### TC-15 — Machine stop and reboot

- **Steps:** EMULATED: kill -9 the daemon and its tracked app together, then start with a different kernel boot_id (CAL_BOOT_ID_FILE hook)
- **Expected:** Previous session marked POWER_LOSS (end estimated from the last heartbeat); a new ACTIVE session opens; no ACTIVE zombie
- **Actual:** previous session status=POWER_LOSS; ACTIVE rows now=1. NOT a real reboot: this container cannot be rebooted, and no systemd/logind boot sequence was exercised
- **Result:** **EMULATED**

#### TC-16 — Incomplete records

- **Steps:** App tracked, daemon kill -9, app dies unobserved, daemon restarted; run stats
- **Expected:** App row closed as RECOVERED (estimated end, not COMPLETED); crashed session CRASHED/POWER_LOSS; only one ACTIVE; stats runs, counts them separately, never as normal completions
- **Actual:** orphaned app row: 20261031T195301Z-27491-5b7a,27590,"calapp_f","root",2026-10-31 19:53:04,2026-10-31 19:53:08,4,RECOVERED; ACTIVE rows=1; sessions: COMPLETED CRASHED COMPLETED POWER_LOSS CRASHED ACTIVE ; stats mentions recovered/incomplete: 3 line(s)
- **Result:** **PASS**

#### TC-17 — Reports are created

- **Steps:** ./main.sh report period --name e2e; ./main.sh report verify
- **Expected:** rc 0; session_report, application_activity_report, usage_summary_report + manifest exist; verify passes; the first session appears in the session report
- **Actual:** report rc=0 verify rc=0 files=[application_activity_report.csv report_manifest.csv session_report.csv usage_summary_report.csv ] first-session-rows-in-report=1
- **Result:** **PASS**

#### TC-18 — CSV files are valid

- **Steps:** sessions --check, processes --check, report verify; apps named '=evil' and 'a b' to test formula-injection guard and quoting; constant column count
- **Expected:** All checks rc 0; a name starting with '=' is neutralised (apostrophe) in the CSV; a name with a space is quoted; every processes row has the same number of columns; reports use CRLF
- **Actual:** sessions --check rc=0, processes --check rc=0, columns/row:      58 8 ; '=evil' row: 20261031T195310Z-27635-1e2c,27909,"'=evil","root",2026-10-31 19:53:14,2026-10-31 19:53:18,4,COMPLETED; 'a b' row: 20261031T195310Z-27635-1e2c,27910,"a b","root",2026-10-31 19:53:14,2026-10-31 19:53:18,4,COMPLETED; report CRLF:       4 ok 
- **Result:** **PASS**

#### TC-19 — No duplicated events

- **Steps:** Whole run incl. 2 clean restarts, 3 kill -9 and a power-loss emulation: look for repeated (Session_ID,PID,Start_Time) keys and Session_IDs
- **Expected:** 0 duplicated process keys, 0 duplicated Session_IDs
- **Actual:** process rows=58 duplicate keys=0; duplicated session ids=0
- **Result:** **PASS**

#### TC-20 — CPU and RAM usage

- **Steps:** Daemon with ~145 user processes (60 extra test apps running); measure CPU (utime+stime incl. waited children: ps/awk) and RSS over 30 s at INTERVAL_SEC=1 and 5
- **Expected:** INTERVAL_SEC=1: CPU < 5 % and RSS < 50 MB; INTERVAL_SEC=5: CPU < 2 %
- **Actual:** INTERVAL_SEC=1: CPU 3.17% RSS 6 MB (peak 6 MB); INTERVAL_SEC=5: CPU 0.70% RSS 6 MB (peak 6 MB); 145 processes owned by the user
- **Result:** **PASS**

### قراءة نقدية للنتائج

- **الدقة بالثانية:** TC-06/09/10/11: فروق ±1 ثانية في البدء والنهاية والمدة (في هذا التشغيل سُجّلت مدة 3 ث لعملية عمرها 4 ث، وبعض مدد TC-11 أكبر بثانية). هذا هو الحد المعلن: `Start_Time` مشتق من `uptime − etimes` (كلاهما مقتطع)، و`End_Time` وقت *الاكتشاف*.
- **TC-12 (حد معروف):** عملية عمرها 0.1 ث تُرى فقط إن وقع فحص داخل عمرها (احتمالًا ≈10%): رُصدت 2 من 20 (متوقع)، وسُجّلت بمدة **1 ث لا 0.1 ث**. أي أن مدد العمليات الأقصر من الفاصل مبالغ فيها حتى فاصل واحد. العملية ذات الثلاث ثوانٍ سُجّلت.
- **TC-13:** القتل بالقوة يُسجَّل `COMPLETED` (لا يعرف المستخدم العادي السبب).
- **TC-14:** تحقق السكربت من الصفوف والجلسات (`SESSION_END` ثم `COMPLETED`؛ جلسات `COMPLETED, CRASHED, ACTIVE`). علم «وُجدت تعمل» (`pre=yes`) مفحوص في `test_processes.sh`، لا في هذا السكربت.
- **TC-15 (محاكاة):** `kill -9` للمراقب وتطبيقه معًا ثم تشغيل بمعرّف إقلاع مختلف (`CAL_BOOT_ID_FILE`). **ليست إعادة إقلاع حقيقية.**
- **TC-20:** القياس 30 ثانية لكل فاصل، مع ~145 عملية للمستخدم (60 منها أضافها الاختبار): المراقب ≈ 3% CPU عند فاصل 1 ث و≈0.7% عند 5 ث، وذاكرة 6 MB. لا يثبت شيئًا عن تسرّب ذاكرة على مدى ساعات.

## 4. الأخطاء المكتشفة والإصلاحات

### 4.1 اكتشفتها مراجعة الشيفرة وطبقة `test_review.sh` (الإصدار 0.6.1، التفاصيل في `CHANGELOG.md`)

| # | الخطأ | الإصلاح | الاختبار |
|---|---|---|---|
| 1 | أسماء العمليات غير اللاتينية (العربية) تُسجَّل `???????` لأن `ps` يعمل بـ`LC_ALL=C` | `ps` بـ`C.UTF-8` | R1، smoke |
| 2 | `Command_Name`/`App_Name` نص مقتبس بالصدفة (`'$'\330…`) بسبب `stat -c %N` | `find -printf %l` | R1, R2 |
| 3 | اسم ملف تنفيذي فيه Tab يزحزح حقول سجلات التتبع | تعقيم محارف التحكم | R2 |
| 4 | `daemon_finalize` يمسح `ENDED` فتضيع عملية انتهت في دورة قُطعت | تفريغها قبل الإغلاق | R3 |
| 5 | `storage_save_active` قد يستبدل جدولًا سليمًا بجدول مبتور عند امتلاء القرص | كتابة واحدة مفحوصة ثم `mv` | R4 (يغطي فشل إنشاء الملف المؤقت فقط) |
| 6 | الصف التالي يلتصق بسطر مبتور بعد فشل كتابة | إنهاء السطر المبتور (`STORAGE_DIRTY`) | R5 |
| 7 | `purge` قد يتسابق مع مراقب يبدأ أثناء إعادة الكتابة | يحتفظ بقفل المراقب | R7 (يغطي رفض الأخذ عند وجود قفل، لا السباق نفسه) |
| 8 | ملفات CSV بصلاحيات واسعة من إصدار قديم | `chmod 600` لملفاتنا | R6 |
| 9 | `config.local.sh` يُحمَّل كشيفرة حتى لو قابل للكتابة لغير المالك | يُتجاهل مع رسالة | R9 |
| 10 | `INTERVAL_SEC=08` يفشل كعدد ثماني؛ `LOG_MAX_BYTES` بلا تحقق | تطبيع `10#` + تحقق | R9 |
| 11 | استدعاء `systemctl` في معالج الإيقاف بلا مهلة | `timeout 2` في المعالج **سبّب انحدارًا**: انهيار bash (`longjmp causes uninitialized stack frame`) في ≈ إيقاف من كل 8 (الجلسة `CRASHED`)، كشفه smoke (فشل 3 من 10). الإصلاح النهائي: المعالج لا يشغّل أي أمر؛ القرار في `daemon_finalize` | R13 (24 إيقافًا) |
| 12 | `systemd-notify` يُستدعى كل فحص للـwatchdog | كل `WatchdogSec/4` | R8 |
| 13 | `sleep &` يُترك يتيمًا حاملًا للواصفات عند الإيقاف | يُقتل عند المقاطعة | (مراجعة) |
| 14 | `daemon.pid` يُكتب غير ذرّيًا | ملف مؤقت + `mv` | (مراجعة) |
| 15 | `start` يعلن الفشل إن احتاج المراقب أكثر من ثانية | استطلاع حتى 5 ث | (مراجعة) |
| 16 | `doctor` يفشل (rc 1) إن غاب `column` مع أن README يعدّه اختياريًا، ولا يفحص أدوات يستعملها المنتج فعلًا (`find` `stat` `timeout`…) — اكتشفه فحص القبول على نسخة نظيفة | فحص المجموعة الفعلية المطلوبة و`column` اختياري | R10 |
| 17 | مجلدا `data/` و`reports/` يأتيان من git بصلاحية 755 فتُسرَّد أسماء الملفات لغير المالك | `storage_init` يجعل مجلدات المشروع الافتراضية 700 (لا مسارًا يختاره المستخدم) | R10 |

البنود 11 و13 و14 و15 أُصلحت بتعديل صغير مفحوص بالقراءة، **بلا اختبار آلي مخصّص** — هذا صريح.

### 4.2 اكتشفتها هذه الاختبارات وأُصلحت (مرحلة الخدمة التلقائية)

`$$` في مسار التنفيذ يبقى حرفيًا (لا يُضاعَف) · `Documentation=file://` لا يقبل مسافات (حُذف) · `test_reports.sh` كان يتوقع `ExecStart` غير مقتبس · سكربت اختبار أرسل الإشارة إلى صدفة فرعية فسرّب مسجّلًا · `install.sh` لم يعرض Usage عند خيار خاطئ. وفي مجموعة الخدمة: حذف `RestartPreventExitStatus` أسقط 3 فحوص (اختبار طفرة).

### 4.3 اكتشفتها الاختبارات في المراحل السابقة (من `CLAUDE.md` و`docs/DESIGN.md` §17–§20)

حلقة `read` على ملف `/proc` تجمّد المراقب عند 100% CPU وتتجاهل `SIGTERM` (أُصلحت بـ`mapfile`، ويحمل `test_processes.sh` A13 ضابطًا يُظهر الخلل القديم) · `read` عند EOF يفرّغ متغيراته (كسر «لا تستبدل التقارير غير المتغيرة») · `exit` داخل قاعدة awk يمرّ على `END` ويستبدل رمز الخروج · `main_valid_date` كان يقبل `2026-02-30` · خلية `+00:00` في تقرير تشبه صيغة في Excel · LibreOffice يقسّم النص المختلط في `sharedStrings.xml`.

## 5. أخطاء في الاختبارات نفسها (ليست في المنتج) وتصحيحها

| ما حدث | التصحيح |
|---|---|
| (أ) توقعت أن العمليات القصيرة لا تُسجَّل أبدًا — خطأ؛ تُلتقط احتماليًا بمدة مقرَّبة | صُحّح التوقع ليصف السلوك الحقيقي (TC-12) |
| (ب) اختبار العملية اليتيمة قتل المراقب قبل `MIN_DURATION_SEC` وأعاد التشغيل بمعرّف إقلاع مختلف | انتظار 4 ث وإبقاء معرّف الإقلاع (TC-16) |
| (ج) `disown` جعل `wait` يعود فورًا | استبداله بـ`sleep` (TC-12) |
| (د) خلطت `grep -c` مع `|| echo 0` فطُبع `0\n0` | `errn=$(grep -c … || true)` |
| (هـ) إشارة `TERM` أُرسلت للصدفة الفرعية لا للمراقب فتسرّبت نسخة | قراءة PID الحقيقي من `daemon.pid` |
| (و) الجزء B12: استدعاء `um_start_manager` مرتين أفسد مؤشر المدير | إعادة ترتيب الخطوات |
| (ز) `python3 -` بلا مدخل علّق أمرًا في الطرفية | حذفه |
| (ي) **`test_activity.sh`:** الفحص «تطبيقان متزامنان لـ8 ث ⇒ 8–11 ث» أخفق مرة بقيمة 7 | قياس 8 ث قد يظهر 7 بسبب دقة ±1 ث الموثّقة (اقتطاع `uptime` و`etimes`)، وأُعيد تشغيل الملف 3 مرات: 7 ثم 8 ثم 8 — فعُدّل الحد الأدنى إلى 7 (والغرض من الفحص ألا تُجمع المدتان ≈16) |

## 6. ما لم يُختبر (صراحةً)

1. **إعادة إقلاع حقيقية** (TC-15 محاكاة فقط؛ لا تسلسل إقلاع systemd/logind).
2. **تسجيل دخول رسمي (logind/PAM) وجلسة سطح مكتب**: الدخول مُحاكى بإعادة تشغيل مدير `systemd --user`. فالتحقق من «تبدأ عند تسجيل الدخول لا عند الإقلاع» نُفِّذ على المدير المُحاكى لا على Ubuntu حقيقية.
3. **تطبيقات رسومية حقيقية** وتصنيف `.desktop` على سطح مكتب فعلي.
4. **Microsoft Excel** (LibreOffice بديل غير مطابق 100%).
5. **`shellcheck`** (غير متاح؛ ولم أُثبّته بعدم الحصول على إذن).
6. **قياس طويل الأمد** للذاكرة/CPU (ساعات أو أيام) وحمل عدة آلاف من العمليات.
7. **حقن أعطال على مستوى القرص** (امتلاء فعلي أثناء الكتابة): الإصلاحان 5 و6 فُحصا بمحاكاة محدودة فقط.
8. **اختبار الطفرات** نُفِّذ لمجموعة الخدمة ولطبقة المراجعة (13 فحصًا فشلت على الشيفرة القديمة)، لا لباقي المجموعات في هذه الجولة.
9. اختبارات الحالات العشرين نُفِّذت بالمستخدم `root` داخل الحاوية؛ اختبار الخدمة وحده شغّل المراقب بمستخدم عادي.

## 7. اختبار القبول النهائي من الصفر (`tests/final_check.sh`)

يستنسخ آخر commit في مجلد مؤقت (`git clone`) ويشغّل التعليمات كما في README بالمسارات الافتراضية (بلا متغيرات الاختبار)، ويتحقق من الوثائق مقابل الشيفرة، ثم يجرّب المثبّت تحت مدير `systemd --user` حقيقي.

**النتيجة:** 61 فحصًا، 0 إخفاق في آخر تشغيل. الأقسام: (0) الاستنساخ ووجود الملفات الخمسة وصلاحيات التنفيذ · (1) كل أمر `./main.sh <x>` وكل `service <x>` ومسار سكربت مذكور في الوثائق موجود فعلًا (12 أمرًا) · (2) تدفق README: `doctor` → رفض `start` دون موافقة → `consent --accept` → `start` → منع نسخة ثانية → تطبيقان تجريبيان → `processes --running` → `stop` → الجلسة `COMPLETED` والتطبيقان `COMPLETED` → `--check` ×2 → `stats` → `report`/`report daily`/`verify`/`list` → كل ملف 600 وكل مجلد 700 → `purge` → سحب الموافقة ورفض `start` · (3) `install.sh --bogus` مرفوض، `install.sh --accept` ينجح، الخدمة active وenabled، `service status` برمز 0، `restart`، `stop`، لا عملية متبقية، لا صف `ACTIVE`، `uninstall.sh` يزيل الوحدة ويُبقي البيانات · (4) لا مراقب متبقٍّ.

**ما كشفه هذا الاختبار (ولم تكشفه الطبقات السابقة)، وقد أُصلح:**

1. `./main.sh doctor` كان يفشل (رمز 1) على نظام لا يحوي الأمر `column` مع أن README يصفه اختياريًا؛ وكان لا يفحص أدوات يعتمد عليها البرنامج فعلًا (`find`, `stat`, `timeout`, `sha256sum`…). أُصلح وأُضيف اختبار (R10).
2. مجلدا `data/` و`reports/` يأتيان من git بصلاحية 755 (أسماء الملفات مرئية لغير المالك؛ المحتوى 600). أصبحت `storage_init` تجعل مجلدات المشروع الافتراضية 700.
3. (خطأ في الاختبار نفسه) فحص «لا مراقب متبقٍّ» طابق صدفة التشغيل التي تحوي النص نفسه فأعطى إيجابًا كاذبًا؛ صُحّح بنمط يطابق سطر أوامر المراقب بالكامل.

**قيود هذا الاختبار:** القسم 3 يعمل على مدير `systemd --user` مُنشأ في مساحة أسماء مستقلة لمستخدم مؤقت (الحاوية بلا systemd)، وليس على Ubuntu بجلسة دخول حقيقية؛ والمُستنسخ هو الـcommit الذي سبق ملفات التوثيق الأخيرة (فروقها وثائقية فقط).

## 8. اختبار المستخدم النهائي (QA مستقل)

نُفِّذ سيناريو كامل بمنظور المستخدم (استنساخ من GitHub، تثبيت، بدء تلقائي بعد خروج/دخول، Chrome وxterm على شاشة افتراضية، إغلاق بعضها، إيقاف، تقارير تُفتح في LibreOffice، قطع كهرباء مُحاكى، 3 × `kill -9`) ومقارنة بعيّنة `ps` خارجية كل 0.25 ث. النتائج والتقييم في [`QA_REPORT.md`](QA_REPORT.md). كشف عيبًا واحدًا في المنتج (ثبات اسم العملية) وأُصلح باختبار R11، وآخر في تجربة المستخدم (تلميح المثبّت). بعد الإصلاح: `run_all.sh` كاملًا rc=0 (821 فحصًا).
