# Computer Activity Logger

برنامج **Bash** يعمل في الخلفية على Linux، وبموافقة صريحة من المستخدم، ويسجّل:

- اسم المستخدم ووقت بداية ونهاية كل **جلسة استخدام**.
- كل **عملية** تبدأ أو تنتهي (اسمها فقط)، مع وقت البدء والانتهاء والمدة.

ثم يحوّل ذلك إلى **إحصائيات** و**تقارير CSV** تُفتح مباشرة في Microsoft Excel.

> الحالة: **v0.2 — Session Logger مكتمل** (جلسات في `sessions.csv` بتوقيت UTC، تحديث السجل في مكانه، استعادة بعد الانهيار، قفل ضد الكتابة المتزامنة).
> التصميم الكامل في [`docs/DESIGN.md`](docs/DESIGN.md).

## الخصوصية (ملتزمون بها)

| يُسجَّل | لا يُسجَّل أبدًا |
|---|---|
| اسم العملية، وقت البدء/الانتهاء، المدة | ضغطات المفاتيح، كلمات المرور، الحافظة |
| اسم المستخدم الحالي فقط | وسائط سطر الأوامر (قد تحوي أسرارًا) |
| بداية/نهاية الجلسة | عناوين النوافذ، محتوى الشاشة أو الملفات |
| | أي شيء عن مستخدمين آخرين، أو أي اتصال بالشبكة |

لا يعمل البرنامج قبل موافقتك الصريحة، ويمكنك في أي وقت: `status` · `stop` · `consent --revoke` · `purge --all`.

## المتطلبات

Bash ≥ 4.3 وأدوات Linux القياسية: `ps awk sort cut head flock df date`
(اختياريًا: `column` لتنسيق الجداول، `systemctl` للتشغيل التلقائي). للتحقق: `./main.sh doctor`

## التشغيل السريع

```bash
./main.sh consent        # اقرأ الإشعار واكتب yes للموافقة
./main.sh start          # يبدأ في الخلفية
./main.sh status         # الحالة والمسارات وحجم البيانات
./main.sh stats          # إحصائيات في الطرفية
./main.sh report         # ينشئ تقريرًا في reports/report_<التاريخ>/
./main.sh sessions       # سجل الجلسات (UTC) — أضف --local أو --tz Asia/Riyadh للتوقيت المحلي
./main.sh stop           # يوقف ويحفظ كل السجلات المفتوحة
```

خيارات مفيدة: `stats --from 2026-10-01 --to 2026-10-31 --top 5` ·
`INTERVAL_SEC=2 ./main.sh start` · `./main.sh purge --before 2026-01-01`.

### التشغيل التلقائي (بدون root)

```bash
install/install.sh            # يعرض الإشعار ويسجّل الموافقة ثم يفعّل خدمة systemd للمستخدم
install/uninstall.sh          # يزيل التشغيل التلقائي (تبقى البيانات)
```

الخدمة تبدأ مع أول تسجيل دخول وتنتهي مع آخر تسجيل خروج؛ فتطابق «جلسة الاستخدام».
بدون systemd يُستخدم XDG autostart تلقائيًا.

## هيكل المشروع

```
main.sh                نقطة الدخول (CLI): يوزّع الأوامر على الوحدات
config.sh              كل الإعدادات (قابلة للتجاوز بمتغيرات البيئة أو config.local.sh)
lib/
  common.sh            سجل، وقت، CSV آمن، نوم قابل للمقاطعة
  consent.sh           الموافقة وإشعار الخصوصية
  collector.sh         لقطة العمليات (أمر ps واحد لكل دورة)
  detector.sh          مقارنة اللقطات: عمليات بدأت / انتهت + التصنيف والتجاهل
  session.sh           دورة حياة الجلسة (تُنشئ المعرّف وتستدعي sessionlog)
  sessionlog.sh        Session Logger: ملف sessions.csv (قفل flock، تحديث ذرّي، فحص الصيغة)
  storage.sh           كتابة CSV وملفات الحالة (ذرّية) + إعادة المحاولة عند فشل الكتابة
  recovery.sh          استعادة الجلسة بعد kill -9 أو انقطاع الكهرباء
  daemon.sh            الحلقة الرئيسية والإشارات والإغلاق الآمن
  analyzer.sh          الإحصائيات (awk)
  report.sh            تقارير Excel
conf/                  ignore.list.example · apps.map.example (انسخهما بدون .example للتخصيص)
data/                  السجلات الخام: sessions.csv · processes_YYYY-MM.csv
reports/               التقارير المولّدة
state/                 حالة التشغيل (pid، heartbeat…) — تُنشأ تلقائيًا ولا تُرفع إلى git
install/               install.sh · uninstall.sh · قوالب systemd و autostart
tests/                 run_all.sh · test_sessions.sh (75 فحصًا) · smoke.sh
docs/DESIGN.md         وثيقة التصميم الكاملة
```

## كيف يعمل (باختصار)

1. كل `INTERVAL_SEC` ثانية يأخذ `collector.sh` لقطة بأمر `ps` (عمليات المستخدم فقط، دون وسائط).
2. `detector.sh` يقارنها بالعمليات المتتبَّعة: الجديد يُسجَّل بدايته، والمختفي تُحسب مدته.
   هوية العملية = `PID + وقت البدء الرتيب`، فلا يخدعه إعادة استخدام PID ولا تغيير الساعة.
3. `storage.sh` يضيف صفًا إلى CSV الشهري (UTF-8 + BOM) عند انتهاء كل عملية؛ و`sessionlog.sh` يسجّل الجلسة في `sessions.csv`.
4. تُحدَّث `heartbeat` و`active.tsv` باستمرار؛ إن مات البرنامج فجأة تُغلق `recovery.sh`
   الجلسة والعمليات المفتوحة عند آخر heartbeat (الحالة `CRASHED` / `POWER_LOSS`).
5. أمر `SIGTERM` (إيقاف/تسجيل خروج/إطفاء) يُغلق كل شيء بشكل نظيف (`COMPLETED`).

### الجلسات: `data/sessions.csv`

ملف واحد لكل الجلسات. يُضاف الصف عند **بداية** الجلسة (`ACTIVE`) ويُحدَّث **نفس الصف** عند نهايتها.
كل الأوقات المخزّنة بتوقيت **UTC**؛ التوقيت المحلي للعرض فقط (`sessions --local` / `--tz`).

| العمود | المعنى |
|---|---|
| `Session_ID` | معرّف فريد، مثل `20261031T113121Z-12529-3e81` (وقت UTC + PID + 4 خانات عشوائية) |
| `Username` · `User_ID` | `whoami` و UID |
| `Login_Date` · `Login_Time` | بداية الجلسة (UTC) |
| `Logout_Date` · `Logout_Time` | نهايتها (UTC) — فارغان أثناء الجلسة |
| `Duration_Seconds` | المدة بالثواني (من الساعة الرتيبة، لا تتأثر بتغيير الوقت). الدقائق تظهر في `sessions` وفي `05_sessions.csv` بالتقرير |
| `Status` | انظر الجدول |

| Status | معناه | وقت النهاية |
|---|---|---|
| `ACTIVE` | الجلسة مفتوحة الآن | — |
| `COMPLETED` | تسجيل خروج / إطفاء طبيعي | وقت الإغلاق |
| `ABORTED` | خرج البرنامج بخطأ لكنه حفظ حالته | وقت الخروج |
| `CRASHED` | مات البرنامج فجأة (`kill -9`…) | آخر heartbeat |
| `POWER_LOSS` | أُعيد تشغيل الجهاز / انقطعت الكهرباء | آخر heartbeat |
| `INTERRUPTED` | صف مفتوح بلا أي معلومة عن نهايته | فارغ |

**الحماية:** كل تعديل تحت `flock` حصري؛ يُكتب إلى ملف مؤقت ثم `mv` ذرّي مع نسخة `sessions.csv.bak`؛
الصف لا يُكرَّر (بدء الجلسة idempotent) ولا يُغلق مرتين؛ السطر الممزّق يُصلَح قبل الإضافة؛
ملف بترويسة غريبة يُنقل إلى `sessions.csv.invalid.<وقت>` ولا يُكتب فوقه؛ ولا يُحذف أي سجل سابق إلا بأمر `purge`.
للفحص: `./main.sh sessions --check`.

### أعمدة `processes_YYYY-MM.csv`
`session_id, username, pid, ppid, app_name, process_name, category, start_time, end_time, start_epoch, end_epoch, duration_sec, duration_hms, paused_sec, active_sec, started_before_session, end_reason` — الأوقات UTC أيضًا.
### فتح التقارير في Excel
افتح ملفات `reports/report_*/*.csv` مباشرة. الترميز UTF-8 مع BOM فيظهر العربي صحيحًا،
وأعمدة `*_sec` رقمية للجمع والـ Pivot، وأعمدة `*_hms` للقراءة.
إن ظهرت الأعمدة في خلية واحدة (إعدادات إقليمية تستخدم `;`) فاستخدم *Data ▸ From Text/CSV* واختر الفاصل `,`.

## حدود معروفة

- **الدقة:** العمليات الأقصر من `INTERVAL_SEC` قد لا تُلتقط، ووقت الانتهاء هو وقت *اكتشافه* (تأخير حتى فاصل واحد).
- العمليات التي كانت تعمل قبل بدء الجلسة تُوسم `started_before_session=yes`.
- تقرير يومي: العملية العابرة لمنتصف الليل تُحتسب في يوم بدايتها (تقسيمها مؤجل).
- لم تُنفَّذ بعد (انظر خطة `docs/DESIGN.md` §14): ملف `.xlsx` متعدد الأوراق، فاصل `;` للتقارير، تقرير ساعي.

## الاختبار

```bash
bash tests/run_all.sh     # فحص الصياغة (bash -n) + shellcheck (إن وُجد) + اختبار smoke في بيئة معزولة
```
