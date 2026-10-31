# Computer Activity Logger

برنامج **Bash** يعمل في الخلفية على Linux، وبموافقة صريحة من المستخدم، ويسجّل:

- اسم المستخدم ووقت بداية ونهاية كل **جلسة استخدام**.
- كل **عملية** تبدأ أو تنتهي (اسمها فقط)، مع وقت البدء والانتهاء والمدة.

ثم يحوّل ذلك إلى **إحصائيات** و**تقارير CSV** تُفتح مباشرة في Microsoft Excel.

> الحالة: **v0.1 — الهيكل الأساسي يعمل** (جمع، اكتشاف، CSV، جلسات، استعادة بعد الانهيار، إحصائيات، تقارير).
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
  session.sh           بداية/نهاية الجلسة
  storage.sh           كتابة CSV وملفات الحالة (ذرّية) + إعادة المحاولة عند فشل الكتابة
  recovery.sh          استعادة الجلسة بعد kill -9 أو انقطاع الكهرباء
  daemon.sh            الحلقة الرئيسية والإشارات والإغلاق الآمن
  analyzer.sh          الإحصائيات (awk)
  report.sh            تقارير Excel
conf/                  ignore.list.example · apps.map.example (انسخهما بدون .example للتخصيص)
data/                  السجلات الخام: processes_YYYY-MM.csv · sessions_YYYY-MM.csv
reports/               التقارير المولّدة
state/                 حالة التشغيل (pid، heartbeat…) — تُنشأ تلقائيًا ولا تُرفع إلى git
install/               install.sh · uninstall.sh · قوالب systemd و autostart
tests/                 run_all.sh (bash -n + shellcheck إن وُجد + smoke) · smoke.sh
docs/DESIGN.md         وثيقة التصميم الكاملة
```

## كيف يعمل (باختصار)

1. كل `INTERVAL_SEC` ثانية يأخذ `collector.sh` لقطة بأمر `ps` (عمليات المستخدم فقط، دون وسائط).
2. `detector.sh` يقارنها بالعمليات المتتبَّعة: الجديد يُسجَّل بدايته، والمختفي تُحسب مدته.
   هوية العملية = `PID + وقت البدء الرتيب`، فلا يخدعه إعادة استخدام PID ولا تغيير الساعة.
3. `storage.sh` يضيف صفًا إلى CSV الشهري (UTF-8 + BOM) عند انتهاء كل عملية.
4. تُحدَّث `heartbeat` و`active.tsv` باستمرار؛ إن مات البرنامج فجأة تُغلق `recovery.sh`
   الجلسة والعمليات المفتوحة عند آخر heartbeat (`crash_recovered` / `power_loss_recovered`).
5. أمر `SIGTERM` (إيقاف/تسجيل خروج/إطفاء) يُغلق كل شيء بشكل نظيف (`logout` / `shutdown`).

### أعمدة `processes_YYYY-MM.csv`
`session_id, username, pid, ppid, app_name, process_name, category, start_time, end_time, start_epoch, end_epoch, duration_sec, duration_hms, paused_sec, active_sec, started_before_session, end_reason`

### أعمدة `sessions_YYYY-MM.csv`
`session_id, username, hostname, boot_id, start_time, end_time, start_epoch, end_epoch, duration_sec, duration_hms, paused_sec, end_reason, process_count, interval_sec, version`

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
