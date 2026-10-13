<h1 align="center">Active Directory Alligator Labs</h1>

<p align="center"><img src="images/logo.png" alt="Logo" width="450"/></p>

> 🌐 **English:** [README.md](README.md) · **العربية:** هذا الملف | لدليل التثبيت بالعربية: [INSTALL_AR.md](INSTALL_AR.md)

بيئة مختبر Active Directory مكتفية ذاتيًا، مُعدّة بأخطاء تهيئة مقصودة للتدرّب على اختبار الاختراق.

## نظرة عامة

يقوم مشروع Vagrant هذا بنشر مختبر Active Directory واقعي يغطّي:

- أساسيات AD (النطاقات، الغابات، علاقات الثقة)
- بروتوكولات المصادقة (NTLM، Kerberos)
- هجمات تسميم الشبكة وإعادة التمرير (Relay)
- الوصول إلى بيانات الاعتماد واستخراجها
- تصعيد الصلاحيات عبر إساءة استخدام قوائم التحكم بالوصول (ACL)
- تقنيات الحركة الجانبية (Lateral Movement)
- ما بعد الاستغلال (ADCS، LAPS، MSSQL)

## المتطلبات

| المكوّن | الحد الأدنى للإصدار |
|-----------|----------------|
| Vagrant   | >= 2.3.0       |
| VirtualBox | >= 7.0         |
| الذاكرة (RAM)       | 16 GB          |
| القرص (Disk)      | 150 GB مساحة حرة    |
| نظام التشغيل المضيف   | Windows 10/11، أو macOS، أو Linux |

## البدء السريع

يُدار التنسيق عبر **`setup.py`** (Python 3.8+، مكتبة قياسية فقط).
والملف `./setup.sh` مجرّد غلاف رفيع يستدعيه. تُبنى الأجهزة **واحدًا تلو الآخر،
وبترتيب التبعيّات** — لا يوجد أمر عملاق واحد لـ"نشر كل شيء".

```bash
# 1. ضع ملفات الـ ISO
#    iso/SERVER_EVAL_x64FRE_en-us.iso     (Windows Server 2022)
#    iso/Win10_22H2_English_x64v1.iso     (Windows 10)

# 2. ابنِ صناديق Packer (~45-90 دقيقة لكل صندوق، بالتتابع)
python3 setup.py build-boxes

# 3. ابنِ المختبر جهازًا جهازًا، بترتيب التبعيّات
python3 setup.py build dc01          # جذر الغابة (يُبنى أولًا)
python3 setup.py build dc02          # يتطلّب dc01
python3 setup.py build dc03          # يتطلّب dc01 و dc02 معًا
python3 setup.py build srv01 ws01 ws02 lin01   # الأعضاء (يتطلّبون dc01)

#    ...أو ابنِ كل شيء دفعة واحدة، مع الحفاظ على ترتيب التبعيّات:
python3 setup.py build all           # أضف --parallel لتداخل بناء الأعضاء

# 4. (اختياري، عند الانتهاء) أغلق المختبر أمنيًا
python3 setup.py finalize all        # تقوية + إصلاح تسرّب DNS عبر NAT + عزل (بخطوة واحدة)
#   أو نفّذ الخطوات كلٌّ على حدة:
python3 setup.py harden all          # إزالة بيانات اعتماد vagrant (يقطع إدارة Vagrant)
python3 setup.py seal all            # جعل كل جهاز على بطاقة واحدة فقط 192.168.200.x
```

> **python3 مطلوب.** ثبّته من https://www.python.org/downloads/ (على Debian/Ubuntu: `sudo apt install python3`). ويقوم `./setup.sh` بتمرير الأوامر إلى `setup.py`.

> **فترة التقييم لنظام Windows:** يُبنى صندوقا Windows من ملفات ISO تقييمية صالحة لمدة 180 يومًا. بعد انتهاء المدة سيُغلق Windows نفسه كل ساعة. تحقّق من الوقت المتبقّي: `slmgr /dli`. وأعد التفعيل (حتى 3 مرات): `slmgr /rearm`.

## تبعيّات البناء

لا يمكن بناء أي جهاز إلا بعد أن تكون الأجهزة التي يعتمد عليها **قيد التشغيل
ومُهيّأة بالكامل**. ويفرض `setup.py` ذلك: إذا كانت إحدى التبعيّات مفقودة يتوقف
البناء برسالة صريحة تخبرك بما يجب بناؤه أولًا (ولا يبني التبعيّات تلقائيًا نيابةً
عنك). يجب تسجيل الصناديق أولًا (`build-boxes`).

| الجهاز | يتطلّب (يُبنى أولًا) | السبب |
|---------|--------------------------------|-----|
| **DC01** | *(لا شيء)* | متحكّم نطاق جذر الغابة — يُبنى أولًا. |
| **DC02** | **DC01** | متحكّم نطاق نسخي ينضمّ إلى نطاق `secscope.corp` الموجود على DC01. |
| **DC03** | **DC01 + DC02** | النطاق الفرعي `it.secscope.corp` يحتاج جذر الغابة **و** شريك نسخ متقارب (DC02) قبل `Install-ADDSDomain`. |
| **SRV01** | **DC01** | خادم عضو ينضمّ إلى النطاق؛ تهيئة ADCS/MSSQL/ACL تحتاج كائنات AD من DC01. |
| **WS01** | **DC01** | محطّة عمل تنضمّ إلى النطاق. |
| **WS02** | **DC01** | محطّة عمل تنضمّ إلى النطاق. |
| **LIN01** | **DC01** | عضو Linux ينضمّ عبر SSSD/realmd إلى DC01. |

```
          ┌───────┐
          │ DC01  │  (forest root — build first)
          └───┬───┘
     ┌────────┼───────────────┬────────┬────────┬────────┐
     ▼        ▼               ▼        ▼        ▼        ▼
  ┌──────┐  ┌──────┐       ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
  │ DC02 │  │SRV01 │       │ WS01 │ │ WS02 │ │LIN01 │ │ ...  │
  └──┬───┘  └──────┘       └──────┘ └──────┘ └──────┘ └──────┘
     ▼
  ┌──────┐
  │ DC03 │  (also needs DC01)
  └──────┘
```

**الترتيب المُوصى به:** `dc01` → `dc02` → `dc03` → `srv01`, `ws01`, `ws02`, `lin01`
(الأعضاء مستقلّون عن بعضهم ويحتاجون DC01 فقط، فيمكن بناؤهم بأي ترتيب — أو
تداخلهم عبر `build all --parallel`).

```bash
# أمثلة مرتّبة حسب التبعيّات
python3 setup.py build dc01                 # بلا تبعيّات
python3 setup.py build dc02                 # يحتاج dc01 جاهزًا
python3 setup.py build dc03                 # يحتاج dc01 و dc02 جاهزين
python3 setup.py build srv01 ws01 ws02      # كلٌّ منهم يحتاج dc01 فقط
python3 setup.py build all                  # كل شيء، بترتيب تلقائي
python3 setup.py build all --parallel       # تداخل الأعضاء المستقلّين (تبقى التبعيّات متسلسلة)
```

> الأعضاء (`srv01`/`ws01`/`ws02`/`lin01`) يحتاجون **DC01** فقط، لكن للحصول على غابة
> كاملة تبني عادةً متحكّمات النطاق أولًا (`dc01` → `dc02` → `dc03`) كي توجد كائنات
> النطاق المتبادلة وعلاقة الثقة قبل بناء الأعضاء وتطبيق قوائم ACL الخاصة بهم.

## خيارات سكربت الإعداد

يبني `setup.py` **جهازًا واحدًا في كل مرة** مع فرض صارم للتبعيّات وحارس بناءٍ لمرة
واحدة (يُرفض أي جهاز مبنيّ مسبقًا ما لم تستخدم `rebuild` أو `--force`، تجنّبًا
للأضرار بالموارد). نفّذ `python3 setup.py help` للمرجع الكامل.

```bash
# بناء الصناديق
python3 setup.py build-boxes                 # بناء الصناديق الثلاثة (Win2022 + Win10 + Debian)
python3 setup.py build-boxes --server-only   # Server 2022 فقط
python3 setup.py build-boxes --workstation-only  # Windows 10 فقط
python3 setup.py build-boxes --debian-only   # صندوق Debian فقط (يحتاجه lin01)
python3 setup.py build-boxes --skip-debian   # صندوقا Windows فقط، تخطّي Debian

# بناء الأجهزة (بترتيب التبعيّات، واحدًا واحدًا)
python3 setup.py build dc01                  # جهاز واحد
python3 setup.py build srv01 ws01 ws02       # عدّة أجهزة (بالتتابع)
python3 setup.py build all                   # كل شيء بالترتيب
python3 setup.py build all --parallel        # تداخل الأجهزة المستقلّة
python3 setup.py build all --max-parallel 2  # تحديد سقف التوازي (الافتراضي 2)
python3 setup.py rebuild ws01                # تدمير + إعادة بناء جهاز واحد
python3 setup.py build dc01 --force          # تجاوز حارس البناء لمرة واحدة

# خريطة التبعيّات (حجب صارم):
#   dc01  <- (none)          dc02 <- dc01        dc03 <- dc01, dc02
#   srv01 <- dc01            ws01 <- dc01        ws02 <- dc01   lin01 <- dc01

# التحكّم بالمُخرجات (لأي أمر)
python3 setup.py build dc01 --verbose        # عرض كل مخرجات التهيئة
python3 setup.py build dc01 --quiet          # مخرجات مُقلّلة
python3 setup.py build dc01 --debug          # عرض أخطاء WinRM المكبوتة

# الإدارة
python3 setup.py status                      # جدول حيّ لحالة كل الأجهزة
python3 setup.py finalize <vm>|all           # تقوية + إصلاح تسرّب DNS عبر NAT + عزل
python3 setup.py harden <vm>|all             # إزالة بيانات اعتماد vagrant (بعد البناء)
python3 setup.py seal <vm>|all               # إزالة بطاقة NAT nic1 (بطاقة واحدة)
python3 setup.py unseal <vm>|all             # استعادة بطاقة NAT nic1 (إعادة تفعيل الإدارة)
python3 setup.py destroy <vm>|all            # تدمير جهاز/أجهزة
python3 setup.py help                        # المساعدة الكاملة + خريطة التبعيّات
```

## جرد الأجهزة الافتراضية

| الجهاز   | اسم المضيف | IP             | نظام التشغيل                    | RAM    | المعالجات | الدور                                  |
|------|----------|----------------|-----------------------|--------|------|---------------------------------------|
| dc01 | DC01     | 192.168.200.10  | Windows Server 2022   | 2048 MB | 2   | متحكّم النطاق الأساسي، DNS        |
| dc02 | DC02     | 192.168.200.11  | Windows Server 2022   | 2048 MB | 2   | متحكّم نطاق ثانوي، هدف النسخ      |
| dc03 | DC03     | 192.168.200.12  | Windows Server 2022   | 2048 MB | 2   | متحكّم نطاق فرعي (it.secscope.corp)       |
| srv01| SRV01    | 192.168.200.20  | Windows Server 2022   | 3072 MB | 2   | MSSQL + IIS + ADCS CA                 |
| ws01 | WS01     | 192.168.200.30  | Windows 10 Pro        | 2048 MB | 2   | محطّة عمل في النطاق، محور الارتكاز الأساسي     |
| ws02 | WS02     | 192.168.200.31  | Windows 10 Pro        | 2048 MB | 2   | محطّة عمل في النطاق، تفويض غير مُقيّد|
| lin01| lin01    | 192.168.200.40  | Debian 12             | 1024 MB | 1   | عضو Linux في النطاق، هدف SSH       |

**النطاق:** `secscope.corp` | **NetBIOS:** `SECSCOPE` | **النطاق الفرعي:** `it.secscope.corp`

## إدارة الأجهزة الافتراضية

يمكن إيقاف الأجهزة فُرادى لتحرير الموارد:

```bash
vagrant halt ws01 ws02             # تحرير ~4 GB
vagrant halt dc03 srv01            # تحرير ~5 GB
vagrant halt lin01                 # تحرير ~1 GB
vagrant status                     # التحقّق ممّا يعمل
```

> **ملاحظة:** DC01 مطلوب لكل العمليات (فهو يستضيف النطاق وDNS وKDC). أبقِه قيد التشغيل طوال فترة نشاط المختبر.

## إعداد Kali

نظام Kali Linux **غير** مُدار بواسطة Vagrant. ثبّت Kali يدويًا في VirtualBox:

1. نزّل Kali Linux من [kali.org](https://www.kali.org/get-kali/#kali-virtual-machines)
2. استورد ملف OVA إلى VirtualBox
3. في إعدادات جهاز VirtualBox > Network > Adapter 1: اربطه بـ **NAT Network** باسم `SECSCOPE.CORP`
4. شغّل Kali واضبط IP ثابتًا:
   ```bash
   sudo ip addr add 192.168.200.99/24 dev eth0
   ```
5. أضف مدخلات المختبر إلى `/etc/hosts`:
   ```
   192.168.200.10  dc01.secscope.corp dc01
   192.168.200.11  dc02.secscope.corp dc02
   192.168.200.12  dc03.secscope.corp dc03 it.secscope.corp
   192.168.200.20  srv01.secscope.corp srv01
   192.168.200.30  ws01.secscope.corp ws01
   192.168.200.31  ws02.secscope.corp ws02
   192.168.200.40  lin01.secscope.corp lin01
   ```
6. ثبّت الأدوات المطلوبة:
   ```bash
   sudo apt-get update -qq
   sudo apt-get install -y -qq impacket-scripts responder bloodhound neo4j crackmapexec evil-winrm smbclient ldap-utils krb5-user hashcat john seclists wordlists nmap netcat-openbsd python3-pip golang
   pip3 install bloodhound --quiet
   ```

## بيانات اعتماد النطاق

| اسم المستخدم       | كلمة المرور         | النوع           | ملاحظات                          |
|----------------|------------------|----------------|--------------------------------|
| Administrator  | SecScope2024!    | Domain Admin   | مدير النطاق الأساسي           |
| anakin         | Vader2024!       | Domain Admin   | مستخدم مدير IT                  |
| han            | Solo2024!        | Domain User    | مستخدم IT، HelpDesk، AcctOps     |
| leia           | Princess2024!    | Domain User    | مديرة الموارد البشرية                     |
| luke           | password         | Domain User    | كلمة مرور ضعيفة - هدف للكسر   |
| svc_sql        | SqlService123    | Service Account| قابل لـ Kerberoast                 |
| svc_web        | WebService123    | Service Account| قابل لـ Kerberoast                 |
| svc_backup     | Backup123        | Service Account| عضو في Backup Operators        |
| taskuser       | Task1234!        | Service Account| موجود في LSA Secrets                 |
| nopreauth      | NoPreAuth123     | Domain User    | قابل لـ ASREPRoast                 |
| localadmin     | LocalAdmin2024!  | Local Admin    | حساب محلي على WS01             |
| labuser        | LabUser2024!     | Linux Local    | مستخدم محلي على lin01               |
| exch_admin     | Exchange2024!    | Domain User    | عضو في Organization Management |
| vagrant        | vagrant          | Local (all VMs)| افتراضي Vagrant (يُعطّل بعد harden) |

## طوبولوجيا المختبر

```
                         ┌─────────────────────────────────────┐
                         │       VirtualBox NAT Network        │
                         │   SECSCOPE.CORP (192.168.200.0/24)  │
                         └─────────────────────────────────────┘
                                         │
             ┌────────────┬───────────────┬───────────────┬───────────────┬────────────┬────────────┬
             │            │               │               │               │            │            │
          ┌──┴──┐      ┌──┴──┐         ┌──┴──┐         ┌──┴──┐         ┌──┴──┐      ┌──┴──┐      ┌──┴──┐
          │DC01 │      │DC02 │         │DC03 │         │SRV01│         │WS01 │      │WS02 │      │lin01│
          │ .10 │      │ .11 │         │ .12 │         │ .20 │         │ .30 │      │ .31 │      │ .40 │
          │  DC │      │  DC │         │ IT  │         │IIS+ │         │Win10│      │Win10│      │Deb12│
          │KDC  │      │     │         │  DC │         │MSSQL│         │     │      │     │      │     │
          │DNS  │      │     │         │     │         │ADCS │         │     │      │     │      │     │
          └─────┘      └─────┘         └─────┘         └─────┘         └─────┘      └─────┘      └─────┘

                                       ┌─────────────────────┐
                                       │       Kali Linux    │
                                       │    192.168.200.99   │
                                       │  (Manual install)   │
                                       └─────────────────────┘
```

## خطوات التهيئة (Provisioning)

لكل جهاز افتراضي مهيّئات مُسمّاة يمكن تشغيلها فُرادى:

```bash
# DC01 (common + base يعملان تلقائيًا عند vagrant up؛ أما postboot/dns/objects فيجب تشغيلها يدويًا)
vagrant up dc01                                    # يشغّل common + base + إعادة تشغيل تلقائيًا
vagrant provision dc01 --provision-with postboot     # ترقية غابة AD DS (بدون إعادة تشغيل)
vagrant reload dc01 --force                          # إعادة تشغيل (إلزامية - WinRM يتعطّل بعد الترقية)
vagrant provision dc01 --provision-with dns          # DNS، منطقة عكسية، سجلّات A، LAPS
vagrant provision dc01 --provision-with objects      # مستخدمو AD، المجموعات، ACLs، GPP

# DC02 (common + base يعملان تلقائيًا عند vagrant up)
vagrant up dc02                                    # يشغّل common + base + إعادة تشغيل تلقائيًا
vagrant provision dc02 --provision-with join      # تثبيت AD DS + ترقية
vagrant reload dc02 --force                        # إعادة تشغيل بعد الترقية

# DC03 (نطاق فرعي)
vagrant up dc03                                    # يشغّل common + base + إعادة تشغيل تلقائيًا
vagrant provision dc03 --provision-with join      # تثبيت AD DS + ترقية النطاق الفرعي
vagrant reload dc03 --force                        # إعادة تشغيل بعد الترقية

# SRV01 (common يعمل تلقائيًا عند vagrant up)
vagrant up srv01                                   # يشغّل common + join + إعادة تشغيل تلقائيًا
vagrant provision srv01 --provision-with services    # IIS، SQL، ADCS

# WS01 (common يعمل تلقائيًا عند vagrant up)
vagrant up ws01                                    # يشغّل common + join + إعادة تشغيل تلقائيًا
vagrant provision ws01 --provision-with misconfig    # الثغرات

# WS02 (common يعمل تلقائيًا عند vagrant up)
vagrant up ws02                                    # يشغّل common + join + إعادة تشغيل تلقائيًا
vagrant provision ws02 --provision-with misconfig    # الثغرات

# LIN01
vagrant provision lin01 --provision-with setup
```

## الثغرات المقصودة

| الثغرة                     | الهدف              | الهجوم                             |
|-----------------------------------|---------------------|------------------------------------|
| تعطيل المصادقة المسبقة (Pre-auth)                 | nopreauth           | ASREPRoast                         |
| SPN على حسابات مستخدمين              | svc_sql, svc_web    | Kerberoasting                      |
| تفويض غير مُقيّد          | WS02$               | التقاط TGT عبر PrinterBug         |
| تفويض مُقيّد (بدون PT)    | SRV01$              | إساءة استخدام S4U2Proxy                    |
| تعطيل توقيع SMB              | WS01, WS02          | NTLM Relay                         |
| تفعيل NTLMv1 (LMCompatLvl=0)    | WS01                | التقاط وكسر تجزئة NTLMv1     |
| تفعيل LLMNR / mDNS / NetBIOS    | WS01                | تسميم -> التقاط التجزئة          |
| سجلّ DNS لـ WPAD                   | DNS (dc01)          | تسميم WPAD                     |
| تفعيل WDigest                   | WS01, WS02          | بيانات اعتماد نصّية من LSASS         |
| تعطيل حماية LSA           | WS01                | استخراج LSASS                          |
| بيانات اعتماد مهمّة مجدولة              | WS01                | LSA Secrets                        |
| بيانات اعتماد حساب خدمة في السجلّ | WS01                | LSA Secrets                        |
| GPP cpassword                     | SYSVOL              | Get-GPPPassword                    |
| WriteDACL على النطاق               | مستخدم han            | منح DCSync -> استخراج بيانات الاعتماد         |
| GenericWrite على WS01              | مجموعة HelpDesk      | RBCD -> السيطرة على الجهاز         |
| WriteProperty على Domain Admins    | مجموعة HelpDesk      | إضافة الذات إلى Domain Admins          |
| GenericWrite على AdminSDHolder        | مستخدم han            | استمرارية SDProp                 |
| han في Account Operators          | مستخدم han            | استمرارية عبر مجموعة محميّة        |
| تفعيل xp_cmdshell               | SRV01 MSSQL         | تنفيذ أوامر نظام التشغيل              |
| قالب ADCS ESC1                | SRV01 CA            | شهادة -> TGT                 |
| سجلّ PowerShell                | WS01                | بيانات اعتماد في السجلّ           |
| مفتاح SSH مزروع                   | lin01               | إعادة استخدام/اكتشاف المفتاح             |
| بيانات اعتماد في Bash history                | lin01 (labuser)     | اكتشاف بيانات الاعتماد             |
| Kerberos keytab                   | lin01               | استخراج keytab                  |
| LAPS (اختياري)                   | DC01 / WS01         | قراءة han لكلمة مرور LAPS          |
| ثقة النطاق الفرعي                   | dc03                | TGT بين النطاقات، SID History       |
| Exchange Windows Permissions      | DC01 AD             | WriteDACL على النطاق -> DCSync      |
| Organization Management -> EWP    | DC01 AD             | إضافة الذات إلى Exchange Windows Perm  |
| قالب شهادة ESC1         | SRV01 CA            | المُسجِّل يحدّد الـ subject -> TGT   |

## بعد تشغيل التقوية (Hardening)

بمجرّد تشغيل أمر `harden` (`python3 setup.py harden <vm>|all`، أو كجزء من
`finalize`):
- يُعطَّل/يُحذَف حساب `vagrant` على أجهزة Windows المستهدفة
- تُعطَّل مصادقة WinRM الأساسية (basic auth)
- أوامر `vagrant reload` و`vagrant provision` و`vagrant winrm` لن تعمل بعد الآن

ويقوم `finalize` (`python3 setup.py finalize <vm>|all`) بذلك ثم يعزل الأجهزة
بالترتيب الصحيح، كما يُزيل سجلّات DNS القديمة `10.0.2.*` (تسرّب NAT) من DC01 كي
تُحلّ الأسماء على نطاق `192.168.200.x` فقط. ويمكن لـ `unseal` استعادة بطاقة NAT
لاحقًا، لكنه لا يستعيد حساب `vagrant` المحذوف (ادخل إلى الأجهزة عبر
`Administrator`/`ADMIN_PASS` أو عبر طرفية VirtualBox).

لا تقوِّ جهازًا إلا بعد اكتمال بنائه وجاهزيّته. ولإعادة البناء من الصفر:
```bash
python3 setup.py destroy all
python3 setup.py build all
```

## اللقطات (Snapshots)

خذ لقطات قبل التمارين للتراجع بسهولة:

```bash
vagrant snapshot save dc01 clean
vagrant snapshot save dc02 clean
vagrant snapshot save ws01 clean
```

الاستعادة عبر:
```bash
vagrant snapshot restore dc01 clean
```

## تفاصيل الشبكة

تتّصل جميع الأجهزة عبر شبكة VirtualBox NAT باسم `SECSCOPE.CORP` (الشبكة الفرعية `192.168.200.0/24`). وينشئ الـ Vagrantfile هذه الشبكة تلقائيًا. البطاقة NIC1 هي بطاقة Vagrant NAT الافتراضية (للإدارة). والبطاقة NIC2 هي بطاقة شبكة `SECSCOPE.CORP` NAT بعناوين IP ثابتة تضبطها سكربتات التهيئة.

## استكشاف الأخطاء وإصلاحها

**خطأ مصادقة WinRM بعد ترقية متحكّم النطاق:** بعد `vagrant provision dc01 --provision-with postboot` (أو انضمام `dc02`/`dc03`)، يظهر خطأ أحمر `WinRM::WinRMAuthorizationError`. هذا متوقّع — فترقية AD DS تُبطِل جلسة WinRM. استخدم دائمًا `vagrant reload <vm> --force` بعد الترقية؛ أما `vagrant reload` العادي فسيعلق 30 دقيقة محاولًا WinRM قبل التراجع.

**انتهاء مهلة WinRM:** أجهزة Windows بطيئة في الإقلاع الأول. يضبط الـ Vagrantfile القيم `boot_timeout = 300` و`winrm.timeout = 180`. إن استمرّت المهلات بالانتهاء، زِد هذه القيم في الـ Vagrantfile.

**الصندوق غير موجود (Box not found):** يجب بناء الصناديق الأساسية بـ `python3 setup.py build-boxes` قبل بناء أي جهاز (وأمر `setup.py build` يتحقّق من ذلك مسبقًا ويخبرك). ويبني `build-boxes` الصناديق الثلاثة افتراضيًا — Windows Server 2022، وWindows 10، و`secscope/debian-bookworm` (الذي يُقلع منه `lin01`، المبنيّ محليًا من ISO الـ netinst الخاص بـ Debian).

**"WS01 not found" أثناء تهيئة objects:** يجب أن تنضمّ الأجهزة إلى النطاق قبل أن يتمكّن `dc01_objects.ps1` من تطبيق قوائم ACL عليها. وتُشغّل سكربتات الإعداد تمريرة objects نهائية بعد تشغيل كل الأجهزة.

**فشل تنزيل SQL Server:** سيعرض السكربت تحذيرًا ويتابع. ثبّت SQL Server Express يدويًا على SRV01 عند الحاجة.

**LAPS غير مثبّت:** يحاول سكربت `dc01_dns.ps1` تنزيل LAPS. إن فشل، نزّل `LAPS.x64.msi` من مايكروسوفت وثبّته يدويًا على DC01.

**أسماء مضيفي الأجهزة لا تُحلّ من نظام التشغيل المضيف:** افتراضيًا لا يحرّر Vagrant ملف `hosts` لديك. أضف المدخلات يدويًا:
```
192.168.200.10  dc01.secscope.corp dc01
192.168.200.11  dc02.secscope.corp dc02
192.168.200.12  dc03.secscope.corp dc03 it.secscope.corp
192.168.200.20  srv01.secscope.corp srv01
192.168.200.30  ws01.secscope.corp ws01
192.168.200.31  ws02.secscope.corp ws02
```

**سياسة تنفيذ PowerShell (Windows):** يأتي Windows 11 افتراضيًا بـ `Restricted` الذي يحجب ملفات `.ps1`. نفّذ هذا مرّة واحدة:
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```
أو استخدم دائمًا الراية `-ExecutionPolicy Bypass` مع `powershell`.

**تعارض Hyper-V / WSL2 / Docker (Windows):** لا يمكن إلا لمشرف أجهزة افتراضية واحد استخدام VT-x في وقت واحد. إن فشلت أجهزة Vagrant في الإقلاع برسالة `VT-x is not available`:
```powershell
dism.exe /Online /Disable-Feature:Microsoft-Hyper-V
bcdedit /set hypervisorlaunchtype off
```
أعد التشغيل. راجع [INSTALL.md](INSTALL.md) (أو [INSTALL_AR.md](INSTALL_AR.md)) للتفاصيل.
