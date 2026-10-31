# Computer Activity Logger — وثيقة التصميم والتنفيذ

> **الحالة:** مرحلة التصميم فقط — لا يوجد أي كود تنفيذي بعد.
> **التقنية الأساسية:** Bash Shell Script + أوامر Linux القياسية.
> **الإصدار المستهدف:** v1.0

---

## 1. نظرة عامة

### 1.1 الهدف
برنامج يعمل في الخلفية بعد تسجيل دخول المستخدم (أو إقلاع الجهاز)، ويسجّل **بشفافية وبموافقة صريحة** نشاط المستخدم على Linux:
بداية الجلسة، العمليات التي بدأت وانتهت، ومدة تشغيل كل منها، ثم يحلل البيانات ويُخرج تقارير CSV تُفتح مباشرة في Microsoft Excel.

### 1.2 ما ليس ضمن النطاق (قيود ملزمة)
| ممنوع | السبب |
|---|---|
| Python / C# / Java | القيد التقني للمشروع |
| واجهة رسومية | المشروع Terminal + CSV |
| تسجيل ضغطات المفاتيح، كلمات المرور، محتوى الشاشة/الملفات، عناوين النوافذ | خصوصية |
| تشغيل مخفي أو بدون علم المستخدم | أخلاقيات + قانون |
| تسجيل **وسائط (arguments)** سطر الأوامر | قد تحتوي كلمات مرور/توكنات (`mysql -pSECRET`) |
| مراقبة مستخدمين آخرين بدون موافقتهم | كل مستخدم يشغّل نسخته الخاصة |

### 1.3 مبادئ التصميم
1. **الموافقة أولًا:** لا يبدأ التسجيل قبل موافقة صريحة مسجّلة.
2. **الشفافية:** أمر `cal status` يعرض حالة التسجيل وما يُجمع، وأمر `cal stop`/`cal purge` متاحان دائمًا.
3. **أقل بيانات ممكنة (Data minimization):** اسم العملية فقط، لمستخدم واحد فقط، دون وسائط.
4. **الصمود:** أي إغلاق مفاجئ لا يُفسد البيانات ولا يُضيّع الجلسة.
5. **البساطة:** أدوات قياسية (`ps`, `awk`, `sort`, `date`, `flock`, `systemd`) بلا اعتماديات خارجية.

---

## 2. تحليل المتطلبات التقنية

| # | المتطلب | الحل التقني | الوحدة |
|---|---|---|---|
| 1 | اسم المستخدم + بداية الجلسة | `$USER`/`id -un` + وقت بدء الـ daemon (خدمة `systemd --user` تبدأ عند أول تسجيل دخول) | `session.sh` |
| 2 | مراقبة العمليات النشطة | `ps` كل N ثانية (Polling) | `collector.sh` |
| 3 | اكتشاف عمليات جديدة | فرق Snapshot (الحالي − السابق) | `detector.sh` |
| 4 | اكتشاف عمليات منتهية | فرق Snapshot (السابق − الحالي) | `detector.sh` |
| 5 | مدة التشغيل | `end_mono − start_mono` (ساعة رتيبة، لا تتأثر بتغيّر الوقت) | `detector.sh` |
| 6 | CSV | كتابة append-only بصيغة RFC 4180 | `storage.sh` |
| 7 | إحصائيات | `awk` على ملفات CSV | `analyzer.sh` |
| 8 | تقارير Excel | CSV بترميز UTF-8 مع BOM (ثم `.xlsx` اختياريًا عبر `zip`) | `report.sh` |
| 9 | عمل تلقائي | `systemd --user` service (+ بدائل) | `install/` |

---

## 3. أفضل طريقة لمراقبة العمليات في Linux

### 3.1 الخيارات المدروسة

| الطريقة | الإيجابيات | السلبيات | القرار |
|---|---|---|---|
| **Polling عبر `ps`** | قياسي، بلا صلاحيات خاصة، سهل الاختبار، متوافق مع كل التوزيعات | لا يلتقط العمليات الأقصر من الفاصل الزمني؛ دقة ±الفاصل | ✅ **المعتمد** |
| قراءة `/proc` مباشرة | بلا استدعاء `ps` | أبطأ في Bash الصرف؛ تعقيد التحليل | بديل احتياطي |
| `auditd` | يلتقط كل `exec` | يحتاج root + إعداد نظام + حجم سجلات كبير + أقرب للمراقبة العميقة | ❌ |
| eBPF / `bpftrace` / `execsnoop` | دقيق جدًا | root + اعتماديات + خارج Bash الصرف | ❌ |
| Netlink proc connector | أحداث فورية | غير متاح من Bash، يحتاج root | ❌ |
| `inotifywait /proc` | — | لا يعمل على `/proc` | ❌ |

**القرار:** Polling عبر `ps` بفاصل افتراضي **5 ثوانٍ** (قابل للضبط 1–60).
نقبل بصراحة أن العمليات القصيرة جدًا (مثل `ls`) قد لا تُلتقط، لأن الهدف هو **التطبيقات والعمليات الفعلية**، وليس كل أمر لحظي. يُوثَّق هذا في `cal status` وفي التقارير.

### 3.2 أمر الجمع (Snapshot)

```bash
LC_ALL=C ps -u "$(id -u)" -o pid=,ppid=,etimes=,tty=,comm=
```

- `-u` : عمليات المستخدم الحالي فقط (تقليل البيانات).
- `etimes` : ثواني منذ بدء العملية (ساعة رتيبة).
- `comm` **آخر عمود** لأن اسمه قد يحتوي مسافات (مثل `Web Content`) → يُقرأ بـ `read -r pid ppid etimes tty comm` فيأخذ `comm` الباقي كاملًا.
- `LC_ALL=C` لثبات التنسيق.
- لا نطلب `args`/`cmd` إطلاقًا.

> تم التحقق في بيئة التطوير أن الأمر يعمل بهذا التنسيق (procps-ng 4.0.4، Bash 5.2).

### 3.3 هوية العملية (حل مشكلة إعادة استخدام PID)

PID يُعاد استخدامه، لذا هوية العملية = **`PID + وقت البدء الرتيب`**:

```
uptime_now   = أول حقل من /proc/uptime       (ثوانٍ منذ الإقلاع، رتيب)
start_mono   = uptime_now − etimes           (ثابت طوال حياة العملية)
key          = "<pid>:<start_mono مقرّبًا لأقرب ثانية>"
```
- المطابقة بين لقطتين تسمح بتفاوت ±2 ثانية في `start_mono` (بسبب التقريب).
- إذا ظهر نفس PID بـ `start_mono` مختلف ⇒ العملية القديمة انتهت وعملية جديدة بدأت.
- لأن الحساب كله رتيب، **لا يتأثر بتعديل الساعة/NTP/DST**.
- الوقت الحقيقي للعرض: `start_epoch = now_epoch − etimes` يُحسب عند الاكتشاف ويُخزَّن للتقرير فقط.
- يُضاف `boot_id` (من `/proc/sys/kernel/random/boot_id`) إلى حالة الجلسة للتمييز بين الإقلاعات.

### 3.4 نطاق العمليات المسجّلة
1. عمليات المستخدم الحالي فقط (افتراضيًا).
2. استبعاد threads النواة (`ppid==2`) وأدوات المسجّل نفسه (`ps`, `sleep`, `awk`, و PID الـ daemon).
3. قائمة تجاهل قابلة للتعديل `ignore.list` (مثل `bash`, `sh`, `ssh-agent`, `dbus-daemon`).
4. حد أدنى للمدة `MIN_DURATION_SEC` (افتراضي 2) — ما دونه لا يُكتب.
5. **تصنيف:** `gui_or_service` (tty = `?`) مقابل `terminal` (tty = `pts/N`) + فئات من `apps.map` (browser, editor, office, media, dev, other).

> **لا** نقرأ `/proc/<pid>/environ` أو `cmdline` (قد تحوي أسرارًا). التصنيف يعتمد على الاسم والـ tty فقط.

---

## 4. الأدوات والأوامر المستخدمة

| الوظيفة | الأمر |
|---|---|
| جمع العمليات | `ps`, `/proc/uptime`, `/proc/sys/kernel/random/boot_id` |
| الوقت | `printf '%(%F %T)T' -1` (builtin بلا fork)، `date` عند الحاجة |
| تحليل النصوص | `awk`, `sort`, `cut`, `column`, `tr`, `sed` |
| قفل وتزامن | `flock`, ملف PID |
| استعادة/كتابة ذرّية | `mktemp`, `mv` (atomic rename), `sync` |
| مستخدم/جلسة | `id`, `whoami`, `hostname`, `loginctl` (اختياري) |
| تشغيل تلقائي | `systemctl --user`, `loginctl enable-linger` (اختياري), XDG autostart, `cron @reboot` |
| خفض الأولوية | `nice -n 19`, `ionice -c3` (في ملف الخدمة) |
| `.xlsx` (مرحلة لاحقة) | `zip` + ملفات XML تُكتب بـ `printf` |
| فحص الجودة | `shellcheck`, `shfmt`, `bats-core` (إطار اختبار مكتوب بـ Bash) |

**شرط الإصدار:** Bash ≥ 4.3 (مصفوفات associative، `printf %()T`). يتحقق `cal doctor` من ذلك.

---

## 5. هيكل المشروع

```
Computer-Activity-Logger/
├── README.md
├── LICENSE
├── docs/
│   ├── DESIGN.md                 ← هذه الوثيقة
│   ├── PRIVACY.md                ← ما يُجمع وما لا يُجمع
│   └── CSV_SCHEMA.md             ← تعريف الأعمدة
├── bin/
│   └── cal                       ← الواجهة الوحيدة للمستخدم (CLI dispatcher)
├── lib/
│   ├── common.sh                 ← دوال مشتركة (log, time, csv_escape, lock, fmt_duration)
│   ├── config.sh                 ← تحميل وفحص الإعدادات
│   ├── consent.sh                ← الموافقة وتسجيلها
│   ├── session.sh                ← دورة حياة الجلسة
│   ├── collector.sh              ← أخذ Snapshot للعمليات
│   ├── detector.sh               ← مقارنة اللقطات واستخراج started/ended
│   ├── storage.sh                ← كتابة CSV والحالة (state) بشكل ذرّي
│   ├── recovery.sh               ← استعادة الجلسات غير المكتملة
│   ├── daemon.sh                 ← الحلقة الرئيسية (يربط الوحدات)
│   ├── analyzer.sh               ← الإحصائيات
│   └── report.sh                 ← إنتاج تقارير Excel
├── conf/
│   ├── cal.conf.example
│   ├── ignore.list.example
│   └── apps.map.example          ← comm → الاسم الودّي + الفئة
├── install/
│   ├── install.sh                ← تثبيت + موافقة + تفعيل
│   ├── uninstall.sh
│   ├── cal.service               ← systemd user unit
│   └── cal.desktop               ← بديل XDG autostart
└── tests/
    ├── unit/*.bats
    ├── integration/*.bats
    ├── fixtures/                 ← لقطات ps جاهزة + CSV نموذجية
    └── run_all.sh
```

### مواقع التشغيل (XDG، داخل HOME المستخدم، بلا root)

| النوع | المسار | الصلاحيات |
|---|---|---|
| البرنامج | `~/.local/share/cal/{bin,lib}` | 755 |
| الإعدادات | `~/.config/cal/` (`cal.conf`, `ignore.list`, `apps.map`, `consent`) | 600 |
| البيانات | `~/.local/share/cal/data/` (CSV) | 700 / ملفات 600 |
| الحالة | `$XDG_RUNTIME_DIR/cal/` أو `~/.local/state/cal/` (`active.tsv`, `heartbeat`, `session.state`, `daemon.pid`, `lock`) | 700 |
| التقارير | `~/.local/share/cal/reports/` | 700 |
| سجل البرنامج نفسه | `~/.local/state/cal/cal.log` (يدور بالحجم) | 600 |

`umask 077` يُضبط في بداية كل سكربت.

---

## 6. وظيفة كل ملف (Module)

| الملف | المسؤولية | أهم الدوال | يقرأ | يكتب |
|---|---|---|---|---|
| `bin/cal` | موزّع الأوامر | `cal start\|stop\|status\|stats\|report\|export\|purge\|doctor\|install\|uninstall\|consent` | الإعدادات | — |
| `common.sh` | أدوات مشتركة | `log_info/warn/err`, `now_epoch`, `uptime_s`, `csv_escape`, `csv_safe` (ضد حقن الصيغ), `fmt_hms`, `acquire_lock` | — | cal.log |
| `config.sh` | الإعدادات والافتراضيات والتحقق من القيم | `load_config`, `validate_config` | `cal.conf` | متغيرات عامة |
| `consent.sh` | الموافقة | `require_consent`, `record_consent`, `revoke_consent`, `show_notice` | `consent` | `consent` |
| `session.sh` | بدء/إنهاء الجلسة | `session_begin`, `session_end(reason)`, `session_id` | `session.state` | `session.state`, `sessions_*.csv` |
| `collector.sh` | لقطة العمليات | `take_snapshot` ⇒ مصفوفة `CUR[key]="pid\tppid\tstart_mono\ttty\tcomm"` | `ps`, `/proc/uptime` | الذاكرة |
| `detector.sh` | الفرق بين اللقطات | `diff_snapshots` ⇒ `STARTED[]`, `ENDED[]`; `classify`, `apply_filters`, `accumulate_pause` | `CUR`, `PREV`, `ignore.list`, `apps.map` | الذاكرة |
| `storage.sh` | الكتابة الآمنة | `append_process_row`, `append_session_row`, `save_active_state`, `touch_heartbeat`, `rotate_monthly`, `check_disk_space` | — | CSV + state |
| `recovery.sh` | الاستعادة بعد الانهيار | `recover_previous_session` | `session.state`, `active.tsv`, `heartbeat` | صفوف مغلقة بـ `end_reason` مناسب |
| `daemon.sh` | الحلقة الرئيسية + `trap` | `main_loop`, `on_term`, `detect_suspend_gap` | كل ما سبق | — |
| `analyzer.sh` | إحصائيات | `stats_top_apps`, `stats_daily`, `stats_hourly`, `stats_sessions`, `merge_intervals` | CSV | stdout / CSV |
| `report.sh` | تقارير Excel | `build_report`, `write_csv_bom`, `build_xlsx` (مرحلة لاحقة) | CSV | `reports/` |
| `install.sh` | التثبيت | نسخ الملفات، عرض الإشعار، طلب الموافقة، `systemctl --user enable --now` | — | وحدة systemd |

---

## 7. تبادل البيانات بين المكونات

### 7.1 المخطط

```
                    ┌──────────────┐
  systemd --user ──▶│  daemon.sh   │◀── SIGTERM/INT/HUP, SIGUSR1 (flush)
                    └──────┬───────┘
        كل INTERVAL ثانية  │
        ┌──────────────────┼─────────────────────┐
        ▼                  ▼                     ▼
  collector.sh ──CUR──▶ detector.sh ──STARTED/ENDED──▶ storage.sh
  (ps + /proc)         (diff + filters)                 │
                                                        ├─▶ processes_YYYY-MM.csv   (append)
        session.sh ─────────────────────────────────────┼─▶ sessions_YYYY-MM.csv    (append عند الإغلاق)
        recovery.sh (عند البدء فقط)                      ├─▶ state/active.tsv        (ذرّي)
                                                        └─▶ state/heartbeat         (كل دورة)

  analyzer.sh / report.sh  ◀── يقرآن CSV فقط (للقراءة) ──▶ reports/*.csv (+ .xlsx لاحقًا)
```

### 7.2 قنوات التبادل
| بين | القناة |
|---|---|
| وحدات داخل الـ daemon | متغيرات/مصفوفات Bash عامة (`CUR`, `PREV`, `STARTED`, `ENDED`) ودوال |
| daemon ↔ CLI | ملف PID + `flock` + إشارات (`SIGUSR1` لإجبار الكتابة) + ملفات الحالة |
| daemon → المحلل | ملفات CSV (append-only) فقط — لا اتصال مباشر |
| المحلل → Excel | ملفات CSV/XLSX |

لا توجد sockets ولا قواعد بيانات: **الملف هو الواجهة**.

### 7.3 مخطط ملفات CSV

كل الملفات: UTF-8 **مع BOM**، فاصل `,`، اقتباس `"` وفق RFC 4180، سطر ترويسة، والتواريخ بصيغة `YYYY-MM-DD HH:MM:SS` (يتعرف عليها Excel كتاريخ).

**`sessions_YYYY-MM.csv`** — صف لكل جلسة (يُكتب عند إغلاقها)

| العمود | الوصف |
|---|---|
| `session_id` | `YYYYMMDD-HHMMSS-<pid>` |
| `username` | المستخدم |
| `hostname` | الجهاز |
| `boot_id` | أول 8 أحرف من boot_id |
| `start_time` / `end_time` | بداية/نهاية الجلسة |
| `duration_sec` | المدة (ثواني) |
| `duration_hms` | `HH:MM:SS` |
| `paused_sec` | مجموع فترات الإيقاف/السكون المكتشفة |
| `end_reason` | `logout` \| `shutdown` \| `crash_recovered` \| `power_loss_recovered` |
| `process_count` | عدد العمليات المسجّلة |
| `interval_sec` / `version` | إعدادات المراقبة وإصدار البرنامج |

**`processes_YYYY-MM.csv`** — صف لكل عملية منتهية

| العمود | الوصف |
|---|---|
| `session_id`, `username` | ربط بالجلسة |
| `pid`, `ppid` | معرّفات (للتشخيص) |
| `app_name` | الاسم الودّي من `apps.map` أو `comm` |
| `process_name` | `comm` الأصلي |
| `category` | browser / editor / office / media / dev / terminal / other |
| `start_time` / `end_time` | وقت البدء/الانتهاء |
| `duration_sec` / `duration_hms` | المدة الكلية |
| `paused_sec` | ما يُخصم بسبب السكون |
| `active_sec` | `duration − paused` |
| `started_before_session` | `yes` إن كانت تعمل قبل بدء الجلسة |
| `end_reason` | `exited` \| `session_end` \| `recovered` |

> **تنبيه دقة:** `end_time` = وقت **اكتشاف** الانتهاء (قد يتأخر حتى `INTERVAL` ثانية). يُوثَّق هذا في كل تقرير.

**`active.tsv`** (حالة داخلية، TSV): `key  pid  ppid  start_mono  start_epoch  tty  comm  app_name  category  paused  pre_session`
**`heartbeat`**: سطر واحد `epoch  uptime  boot_id  session_id` يُحدَّث كل دورة.
**`session.state`**: `session_id  start_epoch  start_mono  username  boot_id  interval  paused_total`.

### 7.4 حلقة الـ daemon (Pseudo-code)

```
main():
  umask 077; load_config; require_consent || exit 1
  acquire_lock || exit 0                      # نسخة واحدة فقط
  recover_previous_session                    # §8
  session_begin                               # يكتب session.state
  PREV = {}                                   # أول لقطة: كل العمليات pre_session=yes
  trap on_term TERM INT HUP ; trap flush USR1
  loop:
    t0 = uptime
    gap = (t0 - last_t0) - INTERVAL
    if gap > 3*INTERVAL: add_pause(gap)       # سكون/Suspend
    CUR = take_snapshot()                     # collector
    diff(PREV, CUR) -> STARTED, ENDED         # detector
    for p in ENDED:  append_process_row(p)    # storage
    save_active_state if (STARTED or ENDED)
    touch_heartbeat
    PREV = CUR
    sleep_until(t0 + INTERVAL)                # بدون تراكم انجراف
on_term():
  take_snapshot; كل العمليات المفتوحة -> أغلقها (end_reason=session_end)
  session_end(logout|shutdown); remove state; exit 0
```

---

## 8. إعادة التشغيل والإغلاق غير المتوقع

### 8.1 الإغلاق المنظّم (logout / shutdown / `cal stop`)
`systemd` يرسل `SIGTERM` → `trap` ينفّذ `on_term`: يغلق كل العمليات المفتوحة بـ `end_time=الآن` و`end_reason=session_end`، ثم يكتب صف الجلسة، ثم يحذف ملفات الحالة. في `ExecStop`/`TimeoutStopSec=10` ما يكفي للإنهاء النظيف.

### 8.2 الإغلاق المفاجئ (kill -9 / انقطاع كهرباء / كراش)
يُبنى على ثلاثة عناصر دائمة على القرص:
1. `heartbeat`: آخر وقت سُجّل فيه أن الـ daemon حي (يُكتب ذرّيًا كل دورة).
2. `active.tsv`: العمليات المفتوحة وقت آخر تغيير.
3. `session.state`: بيانات الجلسة غير المغلقة.

عند البدء التالي يفحص `recover_previous_session`:

| الحالة | الكشف | المعالجة |
|---|---|---|
| لا يوجد `session.state` | — | بداية نظيفة |
| `session.state` موجود و`boot_id` **مختلف** عن الحالي | أعيد الإقلاع | إغلاق الجلسة القديمة بـ `end_time = heartbeat`، `end_reason=power_loss_recovered` |
| `boot_id` **نفسه** و PID القديم غير حي | الـ daemon انهار فقط | `end_reason=crash_recovered`؛ العمليات التي ما زالت حية تُكمَل (نعيد تحميلها في `PREV` فتستمر بالتتبع)؛ والمنتهية تُغلق عند `heartbeat` |
| `boot_id` نفسه والـ PID القديم **حي** | نسخة مكررة | `flock` يمنع التشغيل |

كل العمليات في `active.tsv` غير المستمرة تُكتب بـ `end_time = heartbeat` و`end_reason=recovered`. أقصى خطأ في الدقة = فاصل واحد.

### 8.3 ضمانات سلامة الملفات
- **append-only** للـ CSV: سطر واحد بـ `printf >>` (أقل من `PIPE_BUF` ⇒ كتابة ذرّية) تحت `flock`.
- ملفات الحالة: كتابة إلى `mktemp` في نفس المجلد ثم `mv` (rename ذرّي).
- المحلل يتجاهل أي سطر أخير ناقص (عدد حقول غير صحيح).
- `sync` عند إغلاق الجلسة فقط (لا في كل دورة لتقليل I/O).

### 8.4 التشغيل التلقائي
**الأساسي — `systemd --user`:** `~/.config/systemd/user/cal.service`
- يبدأ مع أول تسجيل دخول وينتهي مع آخر تسجيل خروج ⇒ يتطابق تمامًا مع مفهوم «جلسة الاستخدام».
- `Restart=on-failure`, `Nice=19`, `IOSchedulingClass=idle`, `ProtectSystem=strict`, `ReadWritePaths=` لمسارات البيانات فقط.
- **للتشغيل عند الإقلاع بدون دخول:** `loginctl enable-linger` (خيار صريح يُشرح للمستخدم، غير مفعّل افتراضيًا).

**البدائل (تلقائيًا بحسب `cal doctor`):** XDG autostart (`~/.config/autostart/cal.desktop`) للبيئات الرسومية بلا systemd؛ أو `crontab @reboot`.

### 8.5 التعامل مع Suspend/Hibernate وتغيّر الساعة
- `etimes` و`/proc/uptime` يحسبان وقت السكون ⇒ إن كانت الفجوة بين دورتين `> 3×INTERVAL` تُسجَّل فترة `paused` وتُضاف إلى `paused_sec` لكل العمليات المفتوحة، ولا تُحتسب في `active_sec`.
- تغيّر الساعة/NTP/DST لا يؤثر على الهوية والمدد (ساعة رتيبة)؛ يتأثر فقط الوقت المعروض، وهو مقبول.

---

## 9. الإعدادات (`cal.conf`)

```ini
INTERVAL_SEC=5            # 1..60
MIN_DURATION_SEC=2
SCOPE=user                # user (افتراضي) | all (للمدير فقط، بموافقة منفصلة)
LOG_ARGS=no               # ثابت: no — لا يوجد خيار لتفعيله في v1
RETENTION_DAYS=365
MIN_FREE_MB=50            # توقف الكتابة وتنبيه إن قلّت المساحة
CSV_DELIMITER=","         # ";" لإعدادات Excel الإقليمية
DATA_DIR=~/.local/share/cal/data
```

---

## 10. التحديات التقنية والحلول

| # | التحدي | الحل |
|---|---|---|
| 1 | عمليات أقصر من الفاصل لا تُلتقط | فاصل افتراضي 5s قابل للخفض لـ1s؛ التوثيق الصريح؛ الهدف التطبيقات لا الأوامر اللحظية |
| 2 | إعادة استخدام PID | هوية = `pid + start_mono` |
| 3 | أسماء عمليات بمسافات | `comm` آخر عمود في `read` |
| 4 | `comm` مقطوع عند 15 حرفًا | عند طول = 15 فقط: `readlink /proc/PID/exe` لاسم الملف التنفيذي (لا نقرأ cmdline) |
| 5 | تطبيق واحد = عشرات العمليات (Firefox) | حقل `app_name` + **دمج الفترات المتداخلة (interval union)** في `analyzer.sh` حتى لا يُضاعف الوقت 10× |
| 6 | عمليات قبل بدء الجلسة | عند أول لقطة تُوسم `started_before_session=yes` ويقصّ المحلل مدتها عند بداية الجلسة |
| 7 | تغيّر الساعة/NTP/DST | الحساب بالساعة الرتيبة |
| 8 | Suspend/Hibernate | كشف الفجوة و`paused_sec` |
| 9 | انهيار/انقطاع كهرباء | heartbeat + active.tsv + recovery (§8) |
| 10 | تشغيل نسختين | `flock -n` على ملف قفل |
| 11 | قراءة المحلل أثناء الكتابة | append-only + تجاهل السطر الناقص |
| 12 | **حقن الصيغ في Excel** (اسم عملية يبدأ بـ `= + - @`) | `csv_safe` يضيف `'` قبل أي قيمة نصية تبدأ بهذه الأحرف |
| 13 | الترميز العربي/Unicode في Excel | UTF-8 مع BOM |
| 14 | فاصل CSV يختلف حسب لغة Windows | `CSV_DELIMITER` + خيار `report --excel-locale=semicolon` |
| 15 | حجم الملفات (حد Excel ≈ 1,048,576 صف) | تقسيم شهري + تقارير مُلخّصة |
| 16 | أداء Bash مع مئات العمليات | استدعاء `ps` واحد/دورة، builtins فقط في الحلقة (`read`, `printf %()T`, مصفوفات)، `nice`/`ionice`، هدف: < 1% CPU |
| 17 | انجراف `sleep` | `sleep_until(t0+INTERVAL)` |
| 18 | امتلاء القرص | `check_disk_space` وتوقف آمن + تنبيه في `cal.log` |
| 19 | `set -e` يسبب خروجًا غير مرغوب في الحلقات | `set -uo pipefail` + فحص أكواد الإرجاع صراحةً؛ فشل دورة واحدة = تخطّيها وتسجيل تحذير |
| 20 | توزيعات بلا systemd / WSL / حاويات | بدائل XDG/cron + `cal doctor` يختار الأنسب |
| 21 | الخصوصية القانونية | موافقة مكتوبة + `cal status` + `cal purge` + عدم جمع وسائط + ملفات 600 |
| 22 | جلسات متعددة للمستخدم نفسه (SSH + سطح مكتب) | daemon واحد لكل مستخدم؛ الجلسة = عمر الـ daemon؛ `loginctl` اختياريًا لإضافة معلومات الدخول |

---

## 11. الخصوصية والموافقة (تصميم إلزامي)

1. `install.sh` يعرض **إشعارًا واضحًا** (ماذا يُجمع/ماذا لا يُجمع/أين يُخزَّن/كيف يُوقف ويُحذف) ويطلب كتابة `yes` صراحةً، أو `--accept` للتثبيت غير التفاعلي.
2. تُسجَّل الموافقة في `~/.config/cal/consent` (المستخدم، التاريخ، الإصدار). بدونها يرفض الـ daemon العمل.
3. اسم الخدمة وصفها واضحان: `cal.service — Computer Activity Logger (user-consented)`.
4. أوامر الشفافية: `cal status` (حالة + ما يُجمع + حجم البيانات)، `cal stop`، `cal consent --revoke`، `cal purge [--before DATE]`، `cal uninstall`.
5. لا تسجيل في نطاق `SCOPE=all` إلا بتأكيد منفصل وتشغيل من مدير النظام نفسه.
6. `docs/PRIVACY.md` يوثق القائمة الكاملة لما يُجمع (11 عمودًا فقط) وما لا يُجمع.

---

## 12. التحليل والتقارير

### 12.1 الإحصائيات (`analyzer.sh`، awk بمرور واحد)
- أكثر التطبيقات استخدامًا (مجموع `active_sec` بعد دمج الفترات المتداخلة لكل `app_name`).
- عدد مرات تشغيل كل تطبيق ومتوسط/أطول مدة.
- إجمالي وقت الاستخدام اليومي والأسبوعي.
- توزيع النشاط على ساعات اليوم (Heatmap رقمي 24 ساعة × أيام الأسبوع).
- إحصائيات الجلسات: العدد، المتوسط، الأطول، أسباب الإغلاق.
- توزيع حسب الفئة (category).
- فلاتر: `--from YYYY-MM-DD --to YYYY-MM-DD --user NAME --app NAME --top N`.

### 12.2 التقارير (`report.sh`)
أمر `cal report --from … --to … [--format csv|xlsx]` ينتج في `reports/YYYYMMDD_HHMMSS/`:

| الملف | المحتوى |
|---|---|
| `01_summary.csv` | ملخص الفترة (إجمالي الوقت، الجلسات، أكثر تطبيق…) |
| `02_top_apps.csv` | ترتيب التطبيقات |
| `03_daily.csv` | الاستخدام اليومي |
| `04_hourly.csv` | الاستخدام لكل ساعة |
| `05_sessions.csv` | الجلسات |
| `06_processes.csv` | التفاصيل الخام للفترة |

كل ملف: BOM + ترويسة + أعمدة رقمية (ثواني) بجانب نصية (`HH:MM:SS`) لتسهيل `SUM`/Pivot في Excel.
**المرحلة اللاحقة:** `.xlsx` واحد متعدد الأوراق يُبنى بـ `zip` من ملفات OOXML تُكتب بـ `printf` (بلا Python/Java)، مع بديل أبسط SpreadsheetML 2003 إن تعذّر.

---

## 13. خطة الاختبار الشاملة

### 13.1 المستويات
| المستوى | الأداة | ماذا يختبر |
|---|---|---|
| ثابت (Static) | `shellcheck`, `shfmt -d`, `bash -n` | جودة الشيفرة والأخطاء الشائعة |
| وحدات (Unit) | `bats-core` | `csv_escape`, `csv_safe`, `fmt_hms`, `diff_snapshots` على Fixtures، `classify`, `merge_intervals`, تحليل التهيئة |
| تكامل (Integration) | `bats` + `HOME` معزول مؤقت + `INTERVAL=1` | الـ daemon كاملًا |
| فشل (Fault) | `kill`, `SIGSTOP/CONT` | الصمود والاستعادة |
| أداء | `time`, `ps -o %cpu,rss`, مولّد عمليات | حدود الموارد |
| خصوصية/أمان | `grep`, `stat` | عدم تسريب بيانات |
| قبول (E2E/UAT) | `systemd --user` فعلي + Excel/LibreOffice | تجربة المستخدم |

### 13.2 حالات الاختبار الرئيسية

**الجلسات**
- T-S1: بدء الـ daemon يكتب `session.state` باسم المستخدم والوقت الصحيحين.
- T-S2: `cal stop` يُنتج صف جلسة بـ `end_reason=logout` ومدة صحيحة (±INTERVAL).
- T-S3: رفض التشغيل بدون موافقة (exit ≠ 0 ولا ملفات).

**الاكتشاف**
- T-D1: تشغيل `sleep 8` ⇒ صف بمدة 8 ± INTERVAL، و`start_time` صحيح.
- T-D2: عملية تعمل قبل الـ daemon ⇒ `started_before_session=yes`.
- T-D3: 3 عمليات متزامنة بأسماء مختلفة ⇒ 3 صفوف صحيحة.
- T-D4: اسم عملية بمسافات (`cp /bin/sleep "/tmp/My App"`) ⇒ يُسجَّل كاملًا.
- T-D5: محاكاة إعادة استخدام PID (Fixture) ⇒ عمليتان لا واحدة.
- T-D6: عملية أقصر من `MIN_DURATION_SEC` ⇒ لا تُكتب.
- T-D7: عمليات المسجّل نفسه (`ps`, `sleep`) غير مسجلة؛ و`ignore.list` مُحترم.
- T-D8: اسم من 15 حرفًا ⇒ يُستكمل من `exe`.

**الصمود**
- T-F1: `kill -TERM` ⇒ إغلاق نظيف لكل شيء.
- T-F2: `kill -9` ثم إعادة التشغيل ⇒ `crash_recovered` وإغلاق العمليات المفقودة عند آخر heartbeat.
- T-F3: محاكاة انقطاع كهرباء (kill -9 + تغيير `boot_id` وهمي عبر متغير اختبار `CAL_BOOT_ID_FILE`) ⇒ `power_loss_recovered`.
- T-F4: تشغيل نسختين ⇒ الثانية تخرج بهدوء.
- T-F5: `SIGSTOP` لـ 30 ثانية ثم `SIGCONT` ⇒ `paused_sec≈30` و`active_sec` مخصوم.
- T-F6: قفز الساعة (±1 ساعة عبر `faketime` أو متغير حقن الوقت) ⇒ المدد لا تتغير.
- T-F7: قطع كتابة في منتصف سطر ⇒ المحلل يتجاهل السطر الناقص.
- T-F8: قرص ممتلئ (tmpfs صغير) ⇒ توقف آمن + تحذير + بلا تلف.

**CSV/Excel**
- T-C1: عدد الأعمدة ثابت في كل صف (فحص `awk`).
- T-C2: حقول بفواصل/اقتباسات/عربي تُقتبس صحيحًا.
- T-C3: اسم `=cmd|...` يُخرَج `'=cmd|...` (حقن صيغ).
- T-C4: الملف يبدأ بـ BOM (`head -c3 | xxd`).
- T-C5: فتح فعلي في Excel (يدوي) و`soffice --headless --convert-to xlsx` (آلي) دون أخطاء؛ التواريخ تُفهم كتواريخ؛ الأعمدة الرقمية قابلة للجمع.
- T-C6: وضع `;` يعمل في إعدادات إقليمية أوروبية/عربية.

**التحليل**
- T-A1: على Fixture معروفة النتائج ⇒ مطابقة رقمية دقيقة (أعلى التطبيقات، المجاميع اليومية).
- T-A2: تطبيق بـ 5 عمليات متداخلة ⇒ الوقت لا يُضاعَف (دمج الفترات).
- T-A3: عملية تعبر منتصف الليل ⇒ تُقسَّم على يومين في التقرير اليومي.
- T-A4: الفلاتر `--from/--to/--app/--user`.
- T-A5: ملف CSV فارغ/ترويسة فقط ⇒ تقرير فارغ بلا أخطاء.

**التثبيت والتشغيل التلقائي**
- T-I1: `install.sh` مرتين (idempotent).
- T-I2: بعد تسجيل خروج/دخول (أو إعادة إقلاع VM) تعمل الخدمة تلقائيًا وتفتح جلسة جديدة.
- T-I3: `uninstall.sh` يزيل الخدمة والبرنامج ويسأل قبل حذف البيانات.
- T-I4: بدائل XDG/cron عند غياب systemd.

**الأداء** (هدف القبول)
- CPU < 1% و RSS < 30 MB مع 500 عملية متزامنة، فاصل 5s.
- دورة جمع+مقارنة < 200 ms عند 500 عملية.
- اختبار تحمّل 24 ساعة (Soak) بلا تسرب ذاكرة ولا نمو غير مبرر في الملفات.
- معدل كتابة < 5 MB/يوم لاستخدام مكتبي نموذجي.

**الخصوصية والأمان**
- T-P1: تشغيل `sleep 100 --password=hunter2` ثم `grep -r hunter2` في كل ملفات البرنامج ⇒ لا نتائج.
- T-P2: صلاحيات الملفات 600 والمجلدات 700.
- T-P3: لا يقرأ البرنامج `/proc/*/environ` أو `cmdline` (فحص `strace -e openat` / `grep` في الشيفرة).
- T-P4: لا اتصال شبكي (`strace -e trace=network` فارغ).
- T-P5: `cal status` يعرض بدقة ما يُجمع؛ `cal purge` يحذف فعلًا.

### 13.3 مصفوفة البيئات
Ubuntu 22.04/24.04، Debian 12، Fedora (أحدث)، Arch؛ Bash 4.4 و5.x؛ مع systemd ودونه (حاوية Alpine/WSL لاختبار البدائل).

### 13.4 مصفوفة التتبّع (المتطلب ↔ الاختبار)

| المتطلب | الاختبارات |
|---|---|
| 1 جلسة | T-S1, T-S2, T-S3 |
| 2 مراقبة | T-D3, الأداء |
| 3 عمليات جديدة | T-D1, T-D2, T-D4, T-D5 |
| 4 عمليات منتهية | T-D1, T-F1, T-F2 |
| 5 المدة | T-D1, T-F5, T-F6, T-A2 |
| 6 CSV | T-C1, T-C2, T-F7 |
| 7 إحصائيات | T-A1 … T-A5 |
| 8 Excel | T-C3 … T-C6 |
| 9 تلقائي | T-I1 … T-I4 |
| قيود الخصوصية | T-P1 … T-P5 |

---

## 14. خطة التنفيذ (مراحل قابلة للتسليم)

| المرحلة | المحتوى | المخرجات | معيار الإنجاز (DoD) |
|---|---|---|---|
| **0 — الأساس** | هيكل المجلدات، `common.sh`, `config.sh`, CI محلي (`shellcheck`, `bats`)، Fixtures | `tests/run_all.sh` أخضر | اختبارات الدوال المساعدة تمر |
| **1 — النواة** | `collector.sh`, `detector.sh`, `storage.sh` + daemon بحلقة بسيطة بلا استعادة | `processes_*.csv` صحيح | T-D1…T-D8, T-C1/C2 |
| **2 — الجلسات والصمود** | `session.sh`, `recovery.sh`, heartbeat, signals, فجوة السكون | `sessions_*.csv` + استعادة | T-S*, T-F* |
| **3 — الأمان والموافقة والتشغيل التلقائي** | `consent.sh`, `bin/cal` (start/stop/status/doctor/purge), `install.sh`, `cal.service`, بدائل | تثبيت بأمر واحد | T-I*, T-P* |
| **4 — التحليل** | `analyzer.sh` (دمج الفترات، يومي/ساعي، فلاتر) | `cal stats` | T-A* |
| **5 — تقارير Excel** | `report.sh` (CSV+BOM، `csv_safe`، فاصل إقليمي) | `cal report` | T-C3…T-C6 |
| **6 — التقوية والتوثيق** | أداء، Soak 24h، `PRIVACY.md`, `README.md`, `CSV_SCHEMA.md`، مصفوفة التوزيعات | v1.0 | كل أهداف §13 |
| **اختيارية (v1.1+)** | `.xlsx` متعدد الأوراق بـ `zip`؛ أنواع تصنيف أغنى؛ تصدير أسبوعي تلقائي عبر `systemd timer` | — | — |

**ترتيب التنفيذ الموصى به:** 0 → 1 → 2 (نواة موثوقة أولًا) ثم 3 (التشغيل الآمن) ثم 4 → 5 → 6.

---

## 15. مخاطر وقرارات مفتوحة

| البند | التوصية الحالية |
|---|---|
| دقة الـ Polling مقابل الاستهلاك | 5 ثوانٍ افتراضيًا؛ يُراجع بعد قياسات المرحلة 1 |
| هل نُشغّل عند الإقلاع بدون دخول (linger)؟ | لا افتراضيًا؛ خيار صريح موثق |
| ملف `.xlsx` حقيقي أم CSV فقط في v1.0؟ | CSV+BOM في v1.0 (يحقق المتطلب)، و`.xlsx` في v1.1 |
| تسجيل مدة «النشاط الفعلي» (idle detection) | خارج النطاق (يتطلب أدوات رسومية/إدخال) |
| نطاق `SCOPE=all` | مؤجل وغير مفعّل في v1.0 |

---

## 16. ملاحظات التنفيذ (v0.1) — الفروقات عن التصميم

تم تنفيذ الهيكل الأساسي وفق طلب المشروع؛ وهذه الفروقات المقصودة عن §5–§7:

| البند | التصميم | التنفيذ الفعلي |
|---|---|---|
| نقطة الدخول | `bin/cal` | `main.sh` في الجذر |
| الإعدادات | `conf/cal.conf` | `config.sh` (يُحمَّل بـ `source`؛ يمكن تجاوز أي قيمة بمتغير بيئة أو `config.local.sh`) |
| البيانات والتقارير | `~/.local/share/cal/...` | `data/` و`reports/` داخل المشروع (و`state/` للحالة)، كلها خارج git |
| الموافقة | `~/.config/cal/consent` | `.consent` في جذر المشروع (صلاحيات 600) |
| أعمدة `processes_*.csv` | 15 عمودًا | 17: أُضيف `start_epoch` و`end_epoch` (يحتاجهما المحلل لدمج الفترات المتداخلة) |
| أعمدة `sessions_*.csv` | 12 عمودًا | 15: أُضيف `start_epoch` و`end_epoch` و`hostname` ثابتة |
| هوية العملية | مفتاح `pid:start_mono` | المفتاح `pid` + مقارنة `start_mono` بتفاوت ±2 ثانية (نفس النتيجة، أبسط) |
| أسباب إغلاق الجلسة | `logout`/`shutdown`/`crash_recovered`/`power_loss_recovered` | + `error_exit` (خروج غير متوقع من الـ daemon مع حفظ السجلات عبر `trap EXIT`) |
| معالجة الأخطاء | `set -uo pipefail` | `set -u -o pipefail -E` + `trap ERR` يسجّل فقط ولا يوقف؛ بدون `set -e` عمدًا |
| النوم | `sleep_until` | `read -t` على pipe خاص (بدون fork، ويستجيب للإشارات فورًا) |
| threads النواة | `ppid==2` | يُستبعد `pid==2` و`ppid==2` في المُجمّع |
| الاختبارات | bats (وحدات + تكامل) | `tests/smoke.sh` (سيناريوهات E2E في sandbox)؛ اختبارات bats تبقى ضمن المرحلة 6 |
| تقسيم العملية عند منتصف الليل | يوميًا | مؤجل: تُحتسب في يوم بدايتها |

**ما نُفّذ من خطة §14:** المراحل 0 و1 و2 و4 كاملة تقريبًا، والمرحلة 3 جزئيًا (الموافقة والـ CLI والتثبيت)، والمرحلة 5 (CSV + BOM + حماية حقن الصيغ بدون `.xlsx` وبدون فاصل `;`).

---

## 17. Session Logger (v0.2)

يحلّ هذا القسم محلّ مخطط `sessions_YYYY-MM.csv` الوارد في §7.3 وصفوف الجلسات الوارد ذكرها في §8.

**الملف:** `data/sessions.csv` — ملف واحد، تُضاف صف عند بداية الجلسة ويُحدَّث **نفس الصف** عند نهايتها.

| العمود | ملاحظة |
|---|---|
| `Session_ID` | `YYYYMMDDTHHMMSSZ-<pid>-<4 hex>`؛ يُتحقق من عدم وجوده في الملف قبل الاستخدام |
| `Username`, `User_ID` | من `whoami` و`$EUID` |
| `Login_Date`, `Login_Time` | UTC |
| `Logout_Date`, `Logout_Time` | UTC؛ فارغان أثناء الجلسة (ولـ `INTERRUPTED`) |
| `Duration_Seconds` | من الساعة الرتيبة في المسار الطبيعي؛ وفي الاستعادة = آخر heartbeat − بداية الجلسة |
| `Status` | `ACTIVE` · `COMPLETED` · `ABORTED` · `CRASHED` · `POWER_LOSS` · `INTERRUPTED` |

**الدقائق** ليست عمودًا في الملف (حسب المواصفات) بل تُحسب عند العرض (`main.sh sessions`) وتظهر في `05_sessions.csv` بالتقرير كعمود `Duration_Minutes`.

**التوقيت:** يُخزَّن كل شيء UTC بحساب صحيح خالص في Bash (`common_utc_date_time` / `common_utc_to_epoch`، بلا `TZ` ولا `date`) —
لأن `printf '%(...)T'` تعتمد على متغير `TZ` المُصدَّر. العرض المحلي فقط: `sessions --local` أو `--tz Asia/Riyadh`.
وبالتالي صارت أوقات `processes_*.csv` UTC أيضًا (وفيها `start_epoch`/`end_epoch` للمطابقة).

**دورة الحياة والاستعادة**

```
session_begin  : sessionlog_start (صف ACTIVE)  ثم  session.state
daemon يعمل    : heartbeat كل دورة
إيقاف نظيف     : sessionlog_close(COMPLETED | ABORTED)              ← يحدّث نفس الصف
kill -9        : التشغيل التالي: recovery → sessionlog_close(CRASHED, نهاية = heartbeat)
إعادة إقلاع    : boot_id مختلف → sessionlog_close(POWER_LOSS, نهاية = heartbeat)
فُقد session.state : sessionlog_reap_orphans → INTERRUPTED (نهاية فارغة)
```

**الحماية من التلف والتزامن (`lib/sessionlog.sh`)**
1. قفل `flock -x` على `data/.sessions.lock` لكل قراءة-تعديل-كتابة (مهلة 15 ث، re-entrant داخل العملية).
2. التحديث: awk → ملف مؤقت في نفس المجلد → فحص أن عدد الأسطر لم يتغير → نسخ `sessions.csv.bak` → `mv` ذرّي.
3. بدء الجلسة idempotent؛ وإغلاق الصف المغلق لا يفعل شيئًا.
4. السطر الأخير بلا `\n` (كتابة ممزّقة) يُصلَح قبل أي إضافة حتى لا يلتصق به الصف الجديد.
5. ترويسة غير متوقعة ⇒ نقل الملف إلى `sessions.csv.invalid.<وقت>` وبدء ملف جديد (لا حذف).
6. إن اختفى صف الجلسة عند إغلاقها يُضاف صف مغلق كامل بدل ضياع الجلسة.
7. `main.sh sessions --check` يتحقق من: الترويسة، 9 حقول، `Session_ID` صالح وفريد، UID رقمي، صيغ التواريخ، الحالة، اتساق الحقول مع الحالة، وأن الخروج بعد الدخول.
8. `purge --before` وحده يحذف صفوفًا (المغلقة فقط).

**لوحظ أثناء التنفيذ:** دوال الأدوات التي تكتب في متغير يمرّره المستدعي (`printf -v "$1"`) يجب أن تُسمّي متغيراتها المحلية بادئة `__` مميزة، وإلا كتبت في متغيرها المحلي إن وافق اسمه اسم الوجهة (النطاق الديناميكي في Bash).

---

## 18. Process Monitor (v0.3)

يحلّ محلّ مخطط `processes_YYYY-MM.csv` في §7.3 (17 عمودًا شهريًا) وجزء العمليات من §8.

**الملفان (إضافة فقط):**
- `data/processes.csv` — **8 أعمدة بالضبط**: `Session_ID, PID, Process_Name, Username, Start_Time, End_Time, Duration_Seconds, Status`.
- `data/process_details.csv` — 20 عمودًا مرافقة تُربط بالمفتاح `Session_ID + PID + Start_Time` (PPID، اسم الأمر، التصنيف، المجموعة، CPU/ذاكرة، أوقات الاكتشاف…).
- سبب الفصل: التزام صارم بالأعمدة المطلوبة دون فقدان بيانات PPID/الأمر/CPU/الذاكرة/التصنيف المطلوب جمعها.

**الأوقات:** `Start_Time` = وقت بدء العملية في نظام التشغيل (UTC)؛ `End_Time` = `Start_Time + Duration` حيث المدة من الساعة الرتيبة (`uptime − start_mono`)، فالثلاثة متسقة دائمًا. وقت الاكتشاف الفعلي بالجدار في `Detected_Start` / `Detected_End`.

**Status:** `COMPLETED` (رُصد الانتهاء) · `SESSION_END` (أُوقفت المراقبة نظيفًا والعملية تعمل) · `RECOVERED` (ماتت المراقبة؛ النهاية = آخر heartbeat).

**جمع البيانات (بلا sudo):** استدعاء `ps -u $EUID -o pid=,ppid=,etimes=,tty=,user:32=,cputimes=,rss=,comm=` واحد لكل فحص. اسم الملف التنفيذي (`Command_Name`) بـ`stat -c %N /proc/PID/exe` **دفعة واحدة** للعمليات الجديدة فقط. لا `cmdline` ولا `environ`.
عمليات المسجّل نفسه وأحفاده تُستبعد بتتبع سلسلة PPID.

**الهوية:** `PID + start_mono` بتفاوت ±2 ثانية (جذب التقريب). PID بوقت بدء مختلف = عملية جديدة (اختبار A2).

**التصنيف** (لجذر كل شجرة): apps.map ← `.desktop` ← cgroup (`app.slice`/`*.service`) ← يملك `pts` ← خلفية. العملية الابنة تنضم لمجموعة أبيها إن كان تطبيقًا أو يشغّل البرنامج نفسه، ويُتحقق أن الأب أقدم من الابن (حماية من PID معاد). الإحصاءات تعدّ **الجذور** كإطلاقات وتدمج الفترات المتداخلة.

**الاستعادة (`recovery.sh`) — قلب «لا تُعدّ ما في فحص واحد بدايةً»:**
1. حيّة بنفس (PID, start_mono) ← **تُكمَل بسجلها الأصلي** (نفس الجلسة، نفس البدء، نفس علم `pre`)، ولا يُكتب شيء.
2. غائبة أو PID لعملية أخرى أو إعادة إقلاع ← صف `RECOVERED` عند آخر heartbeat.
3. صفها موجود في `processes.csv` فعلًا (مات المراقب بين الكتابة وحفظ الحالة) ← تُتخطّى، فلا تكرار.
4. ما ظهر في أول فحص ولم يكن في الحالة ← `Started_Before_Session=yes`.
5. حفظ `active.tsv` فورًا، و`session.state` لا يُحذف بل يُستبدل ذرّيًا، فلا نافذة بلا حالة.

**الأداء المقاس:** فاصل 5 ث: 0.15% CPU (81 عملية)، 0.60% (281 عملية)، RSS ≈ 6 MB. فاصل 1 ث: 0.75% و2.65%.
المقاييس (CPU/ذاكرة) في مصفوفات منفصلة لا تُعاد كتابتها كل فحص؛ تُقرأ فقط عند الانتهاء.

**حدود صريحة:** العمليات الأقصر من الفحص تُفوَّت (لا تتبع exec دون root)؛ القتل لا يُميَّز عن الخروج؛ دقة البدء ±1 ث.

**لوحظ أثناء الاختبار:** `config.sh` يتحول إلى `conf/*.example` إن لم يكن الملف المحدد موجودًا وقت التحميل، فاختبار أنشأ ملفاته بعد التحميل كتب فوق ملفات المستودع. صار الاختبار ينشئها قبل التحميل ويرفض أي مسار خارج الـ sandbox.

---

## 19. Activity Analyzer (v0.4)

يحلّ محلّ دوال `analyzer_top_apps / analyzer_daily / analyzer_summary` السابقة (§12). الوحدة: `lib/activity.sh`؛ `analyzer.sh` يبقى لعروض الصفوف فقط.

**المبدأ:** قراءة فقط من `sessions.csv` و`processes.csv` و`process_details.csv`؛ تحميل واحد وتحقق (`activity_prepare`) ثم جداول مشتقة بـ awk/sort/uniq. لا يُكتب شيء في `data/` (يتحقق الاختبار بـ sha256 وبقائمة الملفات).

**ثلاثة مقاييس لا تُخلط**
| المقياس | التعريف | ملاحظة |
|---|---|---|
| Total Usage Duration | اتحاد فترات الجلسات **المغلقة** مقصوصة على الفترة | `ACTIVE`/`INTERRUPTED` بلا مدة: تُحصى ولا تُجمع |
| Active_Seconds | اتحاد فترات عمليات التطبيق الواحد (`_act_union`: sort ثم دمج) | عشر عمليات متزامنة = مرة واحدة |
| Process_Seconds | مجموع مدد العمليات | يُعرض بوضوح أنه ليس وقت استخدام |

وقت «وجود تطبيق مستخدم واحد على الأقل يعمل» (`User_App_Active_Time`) اتحاد على كل التطبيقات، فلا يجمع تطبيقين متزامنين.

**الاكتمال:** `COMPLETED` فقط يدخل المتوسطات (`Average Process Duration`، متوسط الـinstance). `SESSION_END` (حدّ أدنى) و`RECOVERED` (نهاية مقدَّرة) تُحصى وتظهر في الملاحظات. لا عمليات مكتملة ⇒ المتوسط فارغ/n/a لا صفر. الـinstance «مكتمل» إذا جذره `COMPLETED` وبدأ أثناء المراقبة.

**التطبيق والإطلاق:** يُعتمد `App_Name`/`App_Instance`/`App_Root` من `process_details.csv` (التجميع الموثوق بالأب → الابن في `detector.sh`). **الإطلاق** = جذر بدأ أثناء المراقبة (`pre=no`)؛ ما وُجد يعمل يُحصى `Already_Running` ويُقاس من لحظة رؤيته (`Detected_Start`) لا من بدئه الحقيقي. صف بلا تفاصيل = `Unknown` لا يُدمج في تطبيق.

**الزمن:** كله UTC. العدّ في يوم البدء؛ المدد تُقسَّم عند منتصف الليل (`day_segments` بحساب صحيح خالص في awk — `mawk` بلا `mktime`) وتُقصّ على الفترة. `--utc-offset` إزاحة ثابتة تحرّك حدود اليوم فقط.

**الجداول:** `activity_summary` · `activity_apps CLASS TOP` · `activity_daily` · `activity_sessions` (عدد العمليات لكل جلسة، مع `Duration_Quality` = EXACT/ESTIMATED/UNKNOWN، وجلسات العمليات اليتيمة `MISSING_SESSION`) · `activity_processes` (مدة كل عملية + `Natural_End` + ملاحظة) · `activity_quality` · `activity_text_report`.

**مقاومة البيانات الناقصة/التالفة:** سطر بعدد حقول خاطئ، تكرار `(Session_ID, PID, Start_Time)`، وقت بدء غير مقروء، `Duration` غير رقمي (يُعاد حسابه من الأوقات)، صف بلا تفاصيل، تفاصيل بلا صف، جلسة بلا مدة — كلها تُعدّ في `07_data_quality.csv` ولا تُسقط الحسابات.

**الاختبار:** `tests/test_activity.sh` — بيانات معروفة النتائج (5 جلسات، 12 عملية، صفوف تالفة عمدًا) والقيم المتوقعة محسوبة يدويًا من الخط الزمني في رأس الملف. جُرّبت أربع **طفرات** مقصودة (متوسط يشمل غير المكتمل، اتحاد صار مجموعًا، ما وُجد يعمل عُدّ إطلاقًا، جلسة مفتوحة جُمعت بمدة مخمَّنة) فاكتشفتها الاختبارات كلها (8 و9 و1→2 و10 إخفاقات).

**قرار:** حدود اليوم الافتراضية UTC؛ للتوقيت المحلي `--utc-offset +03:00` (ثابتة بلا توقيت صيفي — مناطق بالاسم غير مدعومة في الإحصاءات اليومية).

**Incidente (v0.4): تجمّد المراقب.** قراءة `/proc/PID/cgroup` بحلقة `while read ... || [[ -n $line ]]` تدور بلا نهاية إن مات PID بين قراءتين (`read` يفشل بـ ESRCH ويترك المتغير بقيمته السابقة). النتيجة: الـ daemon يتجمد بـ100% CPU ولا يستجيب لـ SIGTERM، فلا يتحدّث heartbeat. ظهر كفشل متقطع (مرة في ~3 تشغيلات كاملة). الإصلاح: `mapfile` بدل الحلقة (يتوقف عند EOF أو أول خطأ)، مع `CAL_PROC_ROOT` لاختبارها بشجرة `/proc` وهمية؛ ومعه `stop` صار يصعّد إلى SIGKILL بعد `STOP_TIMEOUT_SEC` (الافتراضي 10) فلا يبقى المراقب غير قابل للإيقاف. اختبارات: A13 (مع شاهد ضابط يُثبت دوران الأسلوب القديم) وB10 (إيقاف daemon مجمَّد بـ SIGSTOP ثم التعافي).

---

## 20. Report Generator (v0.5)

يحلّ محلّ دالة `report_build` السابقة (مجلد بتوقيت الثانية بثمانية ملفات). الوحدة: `lib/report.sh`؛ الأوامر: `main.sh report daily|period|verify|list`.

**المجموعة (Report set):** ثلاثة تقارير + مانيفست.
`session_report.csv` · `application_activity_report.csv` · `usage_summary_report.csv` · `report_manifest.csv`.
كل ملف يبدأ بعمود `Report_Created_UTC` وصفوفه مرتبة زمنيًا. ملخص الاستخدام جدول **منتظم** (أعمدة ثابتة؛ العمود `Section` يحدد نوع الصف) ليصلح للفلترة والـ Pivot بدل كتل بعناوين مختلفة.

**المسارات:** `reports/daily/<UTC|UTC+0300>/YYYY-MM-DD/` و`reports/period/<tz>/<اسم>/`. المنطقة الزمنية في المسار (بلا `:` لأنها غير مسموحة في Windows) فلا يستبدل تقرير بإزاحة تقريرًا بغيرها.

**الجلسة/العملية العابرة لمنتصف الليل:** تظهر في تقرير كل يوم تعمل فيه، `Started_In_Period` يقول أين بدأت، و`Seconds_In_Period` حصة الفترة منها؛ فمجموع الحصص عبر الأيام = المدة الكاملة، ومجموع حصص جلسات اليوم = استخدام اليوم. (اختبار: العملية P7 = 900 + 900 = 1800.)

**FINAL مقابل PARTIAL:** المجموعة `FINAL` إن انتهى آخر يوم فيها (بحدود الإزاحة)، ولا جلسة `ACTIVE` بدأت قبل نهايته، ولا سجل في `active.tsv` (عملية تُتتبَّع الآن أو بقيت من انهيار) بدأ قبل نهايته — لأن صف تلك العملية سيظهر لاحقًا بـ`Start_Time` ضمن اليوم. غير ذلك `PARTIAL`.

**سياسة التاريخ**
| الحالة | تشغيل عادي | `--refresh` | `--force` |
|---|---|---|---|
| لا مجموعة | يولّد | يولّد | يولّد |
| `FINAL` سليمة | **يتخطى دون حساب** | يعيد الحساب، يستبدل فقط إن اختلفت البصمة | يعيد الكتابة |
| `PARTIAL` | يعيد الحساب، يستبدل فقط إن اختلفت البصمة أو الحالة | = | يعيد الكتابة |
| تالفة/ناقصة (المانيفست لا يطابق) | يصلحها | يصلحها | يصلحها |
كل استبدال لمجموعة `FINAL` (أو تالفة، أو بـ`--force`) يحفظ القديمة أولًا في `revisions/<تاريخ إنشائها>/` بـ hard links (لا نسخ، ويبقى الـinode القديم حيًّا بعد الاستبدال الذرّي).
**بصمة المحتوى** = SHA-256 لأجسام الملفات الثلاثة (بلا عمود تاريخ الإنشاء) + إعداد `REPORT_MAX_ROWS`؛ فالتقرير غير المتغير يحتفظ بتاريخ إنشائه الأصلي، وتغيير شكل الملفات (التقسيم) يُحتسب تغييرًا.

**الكتابة الآمنة**
1. قفل `flock` على `reports/.report.lock`: مولّد واحد في كل مرة (وتُنظَّف مجلدات `.staging.*` العالقة داخل القفل).
2. البناء كله في `reports/.staging.XXXXXX` على نفس نظام الملفات.
3. كل ملف: `sync` ثم `mv -f` (إعادة تسمية ذرّية) إلى مكانه؛ **المانيفست آخر ملف** (فيه SHA-256 لكل ملف).
4. انقطاع في المنتصف ⇒ مانيفست غائب أو لا يطابق ⇒ `report verify` يكشفه والتشغيل التالي يصلحه.
5. سجل `reports/report_log.csv` للأحداث (GENERATED/REPLACED) مع مسار النسخة المؤرشفة.

**قيود Excel المفحوصة (`report_verify_dir`):** BOM، CRLF، عدد أعمدة ثابت، توازن الاقتباس، طول الخلية ≤ 32,767، صيغ التواريخ والأرقام، الترتيب الزمني (عبر الأجزاء)، `Report_Created_UTC` = المانيفست، عدم وجود خلية تبدأ بـ`= + @ -` غير محمية، ≤ 1,048,576 صفًا. الأطول من `REPORT_MAX_ROWS` يُقسَّم `_partN`.

**دروس هذا الإصدار (كشفتها الاختبارات)**
- `read` عند EOF **يُفرغ كل المتغيرات التي يقرأ فيها**: كانت بصمة المانيفست هدف `read` مباشرة فتُفرَّغ دائمًا فيُعاد استبدال كل تقرير في كل تشغيل — أي أن «عدم الاستبدال دون داعٍ» لم يكن يعمل. الحل: القراءة إلى متغير محلي ونسخه داخل جسم الحلقة.
- `--utc-offset` الذي كان يبدأ بـ`+` كُتب في الملف كنص `+00:00`، وهي خلية تشبه الصيغة: صار `UTC+00:00`. (المُدقِّق التقط خلية في ملفاتي أنا.)
- `main_valid_date` كان يقبل `2026-13-01` و`2026-02-30` (فحص شكل فقط)؛ صار يتحقق بتحويل ذهابًا وإيابًا.
- LibreOffice يقسّم النص المختلط (عربي + لاتيني) إلى مقاطع داخل `sharedStrings.xml`؛ تُقارَن النصوص بعد إزالة الوسوم.
- `exit` داخل قاعدة awk يمرّ على `END` الذي قد يستبدل رمز الخروج بنفسه: استخدم علَمًا ثم `exit` واحد في `END`.

**اختبار الطفرات:** عشر طفرات متعمدة في المولّد (عودة عيب `read`، كتابة غير ذرّية، المانيفست أولًا، لا تجميد لـFINAL، لا أرشفة، لا حماية صيغ، LF بدل CRLF، لا قفل، لا ترتيب زمني، البصمة بلا التخطيط) اكتُشفت كلها بالفحوص المقصودة (4–29 إخفاقًا لكل منها).

**حدود صريحة:** لم أشغّل Excel نفسه (LibreOffice بديل وليس مطابقًا 100%). التواريخ نص `YYYY-MM-DD HH:MM:SS` يتعرف عليه Excel تلقائيًا لكن LibreOffice الافتراضي يبقيه نصًا. الفاصل `,` ثابت: في إعدادات إقليمية تستخدم `;` يُستورد الملف عبر *Data ▸ From Text/CSV*. لا تشغّل مجموعتَي اختبار معًا على نفس الجهاز بلا حاجة (تريان عمليات بعضهما).
