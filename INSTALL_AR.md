# Active Directory Alligator Labs — دليل التثبيت

> 🌐 **English:** [INSTALL.md](INSTALL.md) · **العربية:** هذا الملف | للملف التعريفي بالعربية: [README_AR.md](README_AR.md)

تعليمات خطوة بخطوة للانتقال من الصفر إلى مختبر Active Directory يعمل بالكامل.

## قائمة التحقّق قبل التثبيت

| المتطلّب | الحد الأدنى |
|-------------|---------|
| الذاكرة (RAM)         | 16 GB   |
| مساحة القرص الحرّة   | 150 GB  |
| المعالج (CPU)         | 4 أنوية (نواتان للمضيف، ونواتان للأجهزة) |
| المحاكاة الافتراضية | تفعيل Intel VT-x أو AMD-V في BIOS |
| الإنترنت    | اتصال مستقرّ (~25 GB من التنزيلات) |
| نظام التشغيل المضيف     | Windows 10/11، أو macOS 12+، أو Linux (النواة 5.x+) |

---

## 1. تثبيت التبعيّات

### ويندوز (Windows)

1. **VirtualBox 7.0+**
   - التنزيل: https://www.virtualbox.org/wiki/Downloads
   - شغّل المثبّت بالإعدادات الافتراضية. وافق على طلب بطاقة الشبكة.
   - أعد التشغيل بعد التثبيت.

2. **Vagrant 2.3+**
   - التنزيل: https://developer.hashicorp.com/vagrant/downloads
   - شغّل مثبّت MSI. أعد التشغيل بعد التثبيت.

3. **Git** (لاستنساخ المشروع، أو نزّل ZIP من المستودع)
   - التنزيل: https://git-scm.com/download/win
   - مُستحسن: فعّل "Git Bash Here" أثناء التثبيت.

4. **Python 3.8+** (يُشغّل مُنسّق `setup.py`)
   - التنزيل: https://www.python.org/downloads/
   - أثناء التثبيت، فعّل **"Add python.exe to PATH"**.

5. تحقّق من **PowerShell (بصلاحيات المسؤول)**:
   ```powershell
   vagrant --version          # يجب أن يكون >= 2.3.0
   VBoxManage --version       # يجب أن يكون >= 7.0
   python --version           # يجب أن يكون >= 3.8
   ```

> **تعارض Hyper-V:** إذا فشل Vagrant في تشغيل الأجهزة، عطّل Hyper-V وWindows Sandbox وWSL2:
> ```powershell
> dism.exe /Online /Disable-Feature:Microsoft-Hyper-V
> bcdedit /set hypervisorlaunchtype off
> ```
> أعد التشغيل بعد تنفيذ هذه الأوامر. ولإعادة التفعيل عند الانتهاء: `bcdedit /set hypervisorlaunchtype auto`

---

### ماك (macOS)

1. ثبّت Homebrew إن لم يكن موجودًا:
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

2. ثبّت VirtualBox وVagrant:
   ```bash
   brew install --cask virtualbox
   brew install --cask vagrant
   ```

3. تحقّق:
   ```bash
   vagrant --version
   vboxmanage --version
   ```

---

### لينكس (Ubuntu/Debian)

1. **VirtualBox 7.0+** (من Oracle، وليس حزمة التوزيعة):
   ```bash
   wget -q https://www.virtualbox.org/download/oracle_vbox_2016.asc -O- | sudo apt-key add -
   sudo add-apt-repository "deb [arch=amd64] https://download.virtualbox.org/virtualbox/debian $(lsb_release -cs) contrib"
   sudo apt-get update
   sudo apt-get install -y virtualbox-7.0
   ```

2. **Vagrant 2.3+**:
   ```bash
   curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
   sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
   sudo apt-get update
   sudo apt-get install -y vagrant
   ```

3. **صلاحيات المستخدم** — أضف مستخدمك إلى مجموعة `vboxusers`:
   ```bash
   sudo usermod -aG vboxusers $USER
   # سجّل الخروج ثم الدخول مجددًا كي يسري التغيير
   ```

4. **Python 3.8+** (يُشغّل مُنسّق `setup.py`؛ مثبّت مسبقًا عادةً):
   ```bash
   sudo apt-get install -y python3
   ```

5. تحقّق:
   ```bash
   vagrant --version
   vboxmanage --version
   python3 --version
   ```

---

## 2. التحقّق من العتاد

### فحص الذاكرة المتاحة
| نظام التشغيل | الأمر |
|----|---------|
| Windows | `systeminfo | findstr /C:"Total Physical Memory"` |
| macOS | `sysctl hw.memsize` (بالبايت) أو `top -l 1 | head -n 10` |
| Linux | `free -h` |

### فحص مساحة القرص الحرّة
| نظام التشغيل | الأمر |
|----|---------|
| Windows | `wmic logicaldisk get size,freespace,caption` |
| macOS | `df -h /` |
| Linux | `df -h` |

### فحص دعم المحاكاة الافتراضية
| نظام التشغيل | الأمر |
|----|---------|
| Windows | `systeminfo | findstr /C:"Virtualization Enabled"` — إن كان "No"، فعّل VT-x في BIOS |
| macOS | مدعوم افتراضيًا على أجهزة Mac بمعالج Intel |
| Linux | `egrep -c '(vmx|svm)' /proc/cpuinfo` — إن كان 0، فعّل VT-x/AMD-V في BIOS |

> **فترة التقييم لنظام Windows:** صندوقا Windows Server 2022 وWindows 10 هما
> نسختان تقييميّتان صالحتان لمدة **180 يومًا**. بعد انتهاء المدّة يُغلق Windows نفسه
> كل ساعة. تحقّق داخل الجهاز: `slmgr /dli`. وأعد التفعيل (حتى 3 مرات): `slmgr /rearm`.

---

## 3. الحصول على المشروع

```bash
git clone <repository-url> ActiveDirectoryAlligatorLABS
cd ActiveDirectoryAlligatorLABS
```

أو نزّل ملف ZIP وفكّ ضغطه في مجلّد باسم `ActiveDirectoryAlligatorLABS/`.

---

## 4. بناء صناديق Vagrant

يجب بناء صناديق Windows من ملفات ISO قبل أن يتسنّى تشغيل أي جهاز.

### تنزيل ملفات ISO

| ISO / الصورة | من أين تحصل عليها | اسم الملف المتوقّع | SHA256 |
|-----|----------|-------------------|--------|
| Windows Server 2022 (eval) | [مركز تقييم مايكروسوفت](https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022) — اختر نسخة **64-bit ISO** | `SERVER_EVAL_x64FRE_en-us.iso` | `3e4fa6d8507b554856fc9ca6079cc402df11a8b79344871669f0251535255325` |
| Windows 10 22H2 | [تنزيل برامج مايكروسوفت](https://www.microsoft.com/en-us/software-download/windows10ISO) (من Linux تقدّم الصفحة رابط ISO مباشر)، **أو** ابنِ إصدارًا محدّدًا عبر [UUP dump](https://uupdump.net/) → *Windows 10 22H2* → *x64* → *English* → طريقة التنزيل "Download and convert to ISO" | `Win10_22H2_English_x64v1.iso` | `a6f470ca6d331eb353b815c043e327a347f594f37ff525f17764738fe812852e` |
| Debian 12.15.0 netinst | [مباشر (مرآة الأرشيف)](https://laotzu.ftp.acc.umu.se/cdimage/archive/12.15.0/amd64/iso-cd/debian-12.15.0-amd64-netinst.iso) · [فهرس الأرشيف الرسمي](https://cdimage.debian.org/cdimage/archive/12.15.0/amd64/iso-cd/) | `debian-12.15.0-amd64-netinst.iso` | `cd4462c06aa8892e692c0c4b9c17802f38c8ab8690e85cbfb5ccaa5956e9af17` |
| Kali Linux (المهاجم) | [جهاز VirtualBox جاهز](https://www.kali.org/get-kali/#kali-virtual-machines) (مُستحسن — استيراد بلا تثبيت) · [ISO المثبّت](https://www.kali.org/get-kali/#kali-installer-images) | *(جهاز مُستورد، لا يوضع في `iso/`)* | *(تحقّق عبر kali.org)* |

توضع ملفات ISO الخاصة بـ Windows وDebian في مجلّد `iso/` (أعِد تسميتها لتطابق
الاسم المتوقّع). **Kali لا يُبنى بواسطة Packer** — فهو جهاز مهاجم منفصل يُستورد
مباشرةً إلى VirtualBox (انظر القسم §7)؛ ولا يوضع في `iso/`.

> **Windows 10 / UUP dump:** يُنتج UUP dump ملف ISO متعدّد الإصدارات. ويختار
> `Autounattend.xml` الإصدار **`Windows 10 Pro`**، وهو موجود في ملف UUP dump من نوع
> "Pro" أو "consumer editions" — فأيٌّ منهما يعمل.

بعد التنزيل، تحقّق من تطابق قيم التحقّق (checksums):

**Linux/macOS:**
```bash
sha256sum iso/SERVER_EVAL_x64FRE_en-us.iso
sha256sum iso/Win10_22H2_English_x64v1.iso
```

**Windows PowerShell:**
```powershell
Get-FileHash -Algorithm SHA256 iso\SERVER_EVAL_x64FRE_en-us.iso
Get-FileHash -Algorithm SHA256 iso\Win10_22H2_English_x64v1.iso
```

> قد تحدّث مايكروسوفت نسخ الـ ISO مع الوقت. إن لم تطابق قيمة التحقّق لديك القيم
> أعلاه، فقد يكون لديك إصدار أحدث — عدّل متغيّر `iso_checksum` في ملفات Packer
> ذات اللاحقة `.pkr.hcl`، أو مرّره كمتغيّر (`-var "iso_checksum=..."`).

> **يجب أن يطابق الإصدار اسم صورة Autounattend.** يختار التثبيت غير التفاعلي صورة
> Windows محدّدة بالاسم:
> يتوقّع `packer/autounattend/windows-server-2022/Autounattend.xml` القيمة
> **`Windows Server 2022 SERVERSTANDARD`**، ويتوقّع
> `packer/autounattend/windows-10/Autounattend.xml` القيمة **`Windows 10 Pro`**.
> إن قدّمت ملف ISO بإصدار مختلف (مثل صورة Datacenter فقط أو Home/Education)، يفشل
> إعداد Windows برسالة *"no image"* / *"Windows cannot find a product key"*.
> استخدم ملفات ISO المحدّدة أعلاه بالضبط، أو عدّل قيمة `/IMAGE/NAME` في ملف
> `Autounattend.xml` المطابق إلى صورة يحتويها الـ ISO فعلًا
> (`dism /Get-WimInfo /WimFile:<mounted>\sources\install.wim` يسردها).
>
> **صندوق Debian:** يُقلع `lin01` من صندوق `secscope/debian-bookworm` المبنيّ
> محليًا، والذي يبنيه Packer من `iso/debian-12.15.0-amd64-netinst.iso`. ويُبنى
> **افتراضيًا** عبر `build-boxes` (إلى جانب صندوقي Windows). وإن لم يكن ISO الخاص
> بـ Debian موجودًا، يُتخطّى مع تحذير (ولا يُحجب مستخدمو Windows فقط)؛ مرّر
> `--skip-debian` لتخطّيه دائمًا.

### بناء الصناديق

ابنِ الصناديق الأساسية الثلاثة دفعة واحدة (الوضع الافتراضي — Windows Server 2022،
وWindows 10، وصندوق Debian الخاص بـ `lin01`):
```bash
python3 setup.py build-boxes
```
إن لم يكن ISO الخاص بـ Debian في `iso/`، يُتخطّى صندوق Debian مع تحذير ويبقى
صندوقا Windows يُبنيان.

أو ابنِ صندوقًا واحدًا في كل مرة:
```bash
python3 setup.py build-boxes --server-only       # Windows Server 2022 (~45-90 دقيقة)
python3 setup.py build-boxes --workstation-only   # Windows 10 (~45-90 دقيقة)
python3 setup.py build-boxes --debian-only        # Debian (لـ lin01)
python3 setup.py build-boxes --skip-debian        # صندوقا Windows، بلا Debian
```

تحقّق من الصناديق:
```bash
vagrant box list | grep secscope
```

يُفترض أن يظهر:
```
secscope/debian-bookworm           (virtualbox, x.x.x)
secscope/windows-10                (virtualbox, x.x.x)
secscope/windows-server-2022       (virtualbox, x.x.x)
```
(يظهر `secscope/debian-bookworm` فقط إن كان ISO الخاص بـ Debian موجودًا / لم تمرّر
`--skip-debian`. و`lin01` يتطلّبه.)

إن فشل البناء برسالة "box not found"، نفّذ `python3 setup.py build-boxes` أولًا.

---

## 5. بناء المختبر

### البناء جهازًا جهازًا (بترتيب التبعيّات)

يقع التنسيق في **`setup.py`** (Python 3.8+؛ و`./setup.sh` غلاف رفيع). تُبنى الأجهزة
**واحدًا في كل مرة** بترتيب التبعيّات — لا توجد خطوة واحدة لـ"نشر كل شيء". ويمكن بناء
كل جهاز مرّة واحدة فقط (تُرفض المحاولة الثانية ما لم تستخدم `rebuild` أو `--force`).

**ترتيب البناء (مفروض بصرامة):**
```
dc01  ->  dc02  ->  dc03            (dc03 needs BOTH dc01 and dc02)
dc01  ->  {srv01, ws01, ws02, lin01}
```

```bash
python3 setup.py build dc01          # جذر الغابة — يُبنى أولًا
python3 setup.py build dc02          # يتطلّب dc01 قيد التشغيل + مُهيّأ
python3 setup.py build dc03          # يتطلّب dc01 و dc02
python3 setup.py build srv01         # يتطلّب dc01
python3 setup.py build ws01 ws02 lin01
```

ابنِ عدّة أجهزة أو كلها دفعة واحدة (مع الحفاظ على ترتيب التبعيّات):
```bash
python3 setup.py build all                 # بالتتابع، بالترتيب
python3 setup.py build all --parallel       # تداخل الأجهزة المستقلّة
python3 setup.py build all --max-parallel 2 # تحديد سقف التوازي (الافتراضي 2)
```

إن كانت إحدى التبعيّات مفقودة، يتوقّف البناء فورًا برسالة تخبرك بالضبط بما يجب
بناؤه أولًا. تحقّق من الحالة في أي وقت عبر:
```bash
python3 setup.py status
```

**مرجع التبعيّات** (لا يُبنى الجهاز إلا بعد أن تكون تبعيّاته قيد التشغيل
ومُهيّأة بالكامل):

| الجهاز | يتطلّب أولًا | ملاحظات |
|---------|----------------|-------|
| DC01 | — | جذر الغابة؛ يُبنى أولًا. |
| DC02 | DC01 | متحكّم نطاق نسخي في `secscope.corp`. |
| DC03 | DC01 **و** DC02 | النطاق الفرعي `it.secscope.corp` (يحتاج شريك نسخ متقارب). |
| SRV01 | DC01 | عضو: MSSQL + IIS + ADCS. |
| WS01 | DC01 | محطّة عمل. |
| WS02 | DC01 | محطّة عمل. |
| LIN01 | DC01 | عضو Linux (SSSD). |

الترتيب المُوصى به: **dc01 → dc02 → dc03 → srv01, ws01, ws02, lin01**. فالأعضاء
يعتمدون على DC01 فقط وهم مستقلّون عن بعضهم. راجع قسم **تبعيّات البناء** في
`README.md` (أو [README_AR.md](README_AR.md)) للمخطّط الكامل للتبعيّات.

### خيارات البناء

```bash
python3 setup.py build dc01 --force     # تجاوز حارس البناء لمرة واحدة
python3 setup.py rebuild ws01           # تدمير + إعادة بناء جهاز واحد
python3 setup.py build dc01 --verbose   # مخرجات تهيئة كاملة
python3 setup.py build dc01 --quiet     # مخرجات مُقلّلة
```

### الإغلاق الأمني (اختياري، بعد البناء)

يقطع `harden` و`seal` إدارة Vagrant، لذا شغّلهما فقط عند اكتمال الأجهزة. وأسهل
طريقة هي الأمر الموحّد `finalize`، الذي يُشغّل التسلسل كاملًا بالترتيب الصحيح
(التحقّق من عناوين IP الداخلية -> إصلاح تسرّب DNS عبر NAT -> harden -> seal):
```bash
python3 setup.py finalize all        # تقوية + إصلاح DNS + عزل، بخطوة واحدة
python3 setup.py finalize all --no-dns-clean   # ...لكن مع تخطّي تنظيف DNS
```
كما يُزيل `finalize` سجلّات DNS القديمة `10.0.2.*` (تسرّب NAT) من DC01 كي تُحلّ
الأسماء على `192.168.200.x` فقط. وتبقى الخطوات الفردية متاحة إن أردت تحكّمًا أدقّ:
```bash
python3 setup.py harden all          # إزالة بيانات اعتماد vagrant
python3 setup.py seal all            # جعل كل جهاز على بطاقة واحدة 192.168.200.x
python3 setup.py unseal <vm>         # (استعادة بطاقة NAT nic1 لاستعادة الإدارة؛
                                     #  حساب vagrant المحذوف لا يُستعاد)
```

---

## 6. التحقّق من المختبر

```bash
./setup.sh status
```

المُخرَج المتوقّع — كل الأجهزة `running`:
```
dc01    running (virtualbox)
dc02    running (virtualbox)
dc03    running (virtualbox)
srv01   running (virtualbox)
ws01    running (virtualbox)
ws02    running (virtualbox)
lin01   running (virtualbox)
```

إن ظهر أي جهاز بحالة `poweroff` أو `not created`، أعد تشغيل البناء:
```bash
./setup.sh
```

---

## 7. تثبيت Kali Linux

نظام Kali **غير** مُدار بواسطة Vagrant. ثبّته يدويًا كمحطّة عمل للمهاجم.

### 7.1 التنزيل والاستيراد

1. نزّل صورة VirtualBox من: https://www.kali.org/get-kali/#kali-virtual-machines
2. في VirtualBox، اذهب إلى **File > Import Appliance** واختر ملف OVA المُنزَّل.
3. شغّل الجهاز بعد الاستيراد (بيانات الاعتماد الافتراضية: `kali` / `kali`).

### 7.2 الربط بشبكة المختبر

1. مع إيقاف جهاز Kali، اذهب إلى **Settings > Network > Adapter 1**
2. اضبط **Attached to: NAT Network**
3. اضبط **Name: SECSCOPE.CORP** (يُنشأ تلقائيًا بواسطة مُشغِّل الـ Vagrantfile)
4. شغّل جهاز Kali.

### 7.3 ضبط IP ثابت

```bash
sudo ip addr add 192.168.200.99/24 dev eth0
```

لجعله دائمًا، عدّل `/etc/network/interfaces`:
```
auto eth0
iface eth0 inet static
    address 192.168.200.99
    netmask 255.255.255.0
```

### 7.4 تثبيت أدوات الهجوم

```bash
sudo apt-get update -qq

sudo apt-get install -y -qq \
    impacket-scripts \
    responder \
    bloodhound \
    neo4j \
    crackmapexec \
    evil-winrm \
    smbclient \
    ldap-utils \
    krb5-user \
    hashcat \
    john \
    seclists \
    wordlists \
    nmap \
    netcat-openbsd \
    python3-pip \
    golang

pip3 install bloodhound --quiet
```

### 7.5 ضبط تحليل الأسماء على المضيف

```bash
sudo tee -a /etc/hosts <<EOF
192.168.200.10  dc01.secscope.corp dc01
192.168.200.11  dc02.secscope.corp dc02
192.168.200.12  dc03.secscope.corp dc03 it.secscope.corp
192.168.200.20  srv01.secscope.corp srv01
192.168.200.30  ws01.secscope.corp ws01
192.168.200.31  ws02.secscope.corp ws02
192.168.200.40  lin01.secscope.corp lin01
EOF
```

### 7.6 ضبط Kerberos

```bash
sudo tee /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = SECSCOPE.CORP
    dns_lookup_realm = false
    dns_lookup_kdc = true

[realms]
    SECSCOPE.CORP = {
        kdc = dc01.secscope.corp
        admin_server = dc01.secscope.corp
    }

[domain_realm]
    .secscope.corp = SECSCOPE.CORP
    secscope.corp = SECSCOPE.CORP
EOF
```

---

## 8. التحقّق / اختبارات الدخان (Smoke Tests)

نفّذ هذه من جهاز Kali للتأكّد من أن المختبر يعمل.

### الاتصال الأساسي
```bash
for ip in 10 11 12 20 30 31 40; do
    ping -c 1 192.168.200.$ip && echo "192.168.200.$ip OK" || echo "192.168.200.$ip FAIL"
done
```

### تحليل DNS
```bash
nslookup dc01.secscope.corp 192.168.200.10
nslookup ws01.secscope.corp 192.168.200.10
```

### مصادقة النطاق (SMB)
```bash
crackmapexec smb 192.168.200.10 -u anakin -p 'Vader2024!'
# المتوقّع: [+] secscope.corp\anakin (Pwn3d!)
```

### Kerberos
```bash
echo 'Vader2024!' | kinit anakin@SECSCOPE.CORP
klist
# المتوقّع: تخزين التذاكر يُظهر anakin@SECSCOPE.CORP
```

### ASREPRoast
```bash
impacket-GetNPUsers secscope.corp/nopreauth -no-pass -request
# المتوقّع: يُرجع TGT مُشفّرًا بمفتاح RC4 الخاص بـ nopreauth
```

### مشاركات SMB
```bash
smbclient -L //192.168.200.10 -U anakin%'Vader2024!'
# المتوقّع: يسرد SYSVOL وNETLOGON ومشاركات أخرى
```

### SSH على Linux
```bash
ssh labuser@192.168.200.40
# كلمة المرور: LabUser2024!
# المتوقّع: تسجيل دخول ناجح
```

---

## 9. جرد الأدوات

الأدوات التي تُثبَّت تلقائيًا على كل جهاز عبر سكربتات التهيئة:

| الجهاز   | البرامج المثبّتة |
|------|--------------------|
| dc01 | Active Directory Domain Services, DNS Server, RSAT AD PowerShell, LAPS MSI |
| dc02 | Active Directory Domain Services, DNS Server |
| dc03 | Active Directory Domain Services, DNS Server |
| srv01 | IIS Web Server, SQL Server Express (محاولة)، ADCS Certificate Authority, ADCS Web Enrollment |
| ws01 | (مُهيّأ بأخطاء مقصودة: WDigest، NTLMv1، LLMNR/mDNS/NetBIOS، تعطيل توقيع SMB/حماية LSA، مسؤول محلي، مهمّة مجدولة، بيانات اعتماد خدمة، AutoLogon كـ anakin، بيانات DCC2 مخزّنة لـ anakin+han) |
| ws02 | (مُهيّأ بأخطاء مقصودة: WDigest، تعطيل توقيع SMB، Print Spooler، AutoLogon كـ anakin) |
| lin01 | SSSD, realmd, adcli, أدوات Kerberos, Samba, OpenSSH, Python3, nmap |

---

## 10. تقديرات الزمن

| المرحلة | الزمن التقريبي |
|-------|-----------------|
| تثبيت VirtualBox + Vagrant | 10-15 دقيقة |
| بناء صندوق Windows Server 2022 | 45-90 دقيقة |
| بناء صندوق Windows 10 | 45-90 دقيقة |
| بناء صندوق Debian Bookworm | 10-20 دقيقة |
| نشر المختبر (./setup.sh) | 75-90 دقيقة |
| إعداد جهاز Kali | 15-20 دقيقة |
| **الإجمالي (باستثناء بناء الصناديق)** | **~ساعتان** |

---

## 11. مشكلات التثبيت الشائعة

### تعارض VirtualBox / Hyper-V (Windows)
**العَرَض:** `VT-x is not available` أو فشل تشغيل الجهاز برسالة `VERR_VMX_NO_VMX`.

**الحل:** لا يمكن إلا لمشرف أجهزة افتراضية واحد استخدام VT-x في وقت واحد. عطّل Hyper-V:
```powershell
dism.exe /Online /Disable-Feature:Microsoft-Hyper-V
bcdedit /set hypervisorlaunchtype off
```
أعد التشغيل. ولإعادة التفعيل: `bcdedit /set hypervisorlaunchtype auto`

وعطّل أيضًا **Windows Sandbox** و**WSL2** و**Credential Guard** إن كانت مفعّلة.

### صندوق Vagrant غير موجود
**العَرَض:** `The box 'secscope/windows-server-2022' could not be found.`

**الحل:** يجب بناء الصناديق من ISO قبل تشغيل المختبر:
```bash
./setup.sh build-boxes
```

### انتهاء مهلة WinRM
**العَرَض:** `Timed out while waiting for the machine to boot` أو أخطاء اتصال WinRM.

**الحل:** أجهزة Windows بطيئة في الإقلاع الأول. يضبط الـ Vagrantfile القيمة
`boot_timeout = 300` (5 دقائق). إن استمرّت المهلات بالانتهاء، زِد هذه القيمة في
الـ Vagrantfile مؤقتًا.

### تعارض المنافذ
**العَرَض:** لا يستطيع Vagrant إعادة توجيه منافذ WinRM (5985، 5986).

**الحل:** يستخدم كل جهاز Windows هذه المنافذ. يربطها VirtualBox بمنافذ مضيفة
عشوائية، لكن إن كان المضيف يشغّل WinRM بنفسه فأوقفه:
```powershell
# على مضيف Windows فقط
Stop-Service WinRM
```

### شبكة NAT موجودة بالفعل
**العَرَض:** خطأ من VBoxManage حول وجود شبكة NAT.

**الحل:** هذا غير ضارّ. يتعامل مُشغِّل الـ Vagrantfile مع ذلك تلقائيًا.
وإن احتجت لإعادة ضبطها:
```bash
VBoxManage natnetwork remove --netname SECSCOPE.CORP
```

### سكربت objects على DC01 — "WS01 not found"
**العَرَض:** أثناء تهيئة objects، قد لا تكون كائنات أجهزة WS01 وWS02 موجودة بعد.

**الحل:** يتخطّى السكربت بأمان قوائم ACL للأجهزة الغائبة ويطبع رسالة واضحة.
وتُشغّل سكربتات الإعداد تمريرة objects نهائية بعد تشغيل كل الأجهزة. أو أعد التشغيل يدويًا:
```bash
vagrant provision dc01 --provision-with objects
```

### مساحة قرص منخفضة
**العَرَض:** يفشل `vagrant up` بأخطاء قرص.

**الحل:**
- كل صندوق جهاز Windows بحجم ~10 GB مضغوطًا، و~40 GB بعد التوسّع
- يستهلك المختبر كاملًا ~100-120 GB بعد إنشاء كل الأجهزة
- نظّف الصناديق القديمة: `vagrant box remove <name>`
- أو حرّر مساحة في: `~/.vagrant.d/boxes/` (Linux/macOS) أو `%USERPROFILE%\.vagrant.d\boxes\` (Windows)

---

## 12. إلغاء التثبيت / إعادة البناء

### تدمير كل الأجهزة (مع الإبقاء على الصناديق)
```bash
./setup.sh destroy
```

### تدمير كل شيء بما في ذلك الصناديق
```bash
./setup.sh destroy
vagrant box remove secscope/windows-server-2022
vagrant box remove secscope/windows-10
vagrant box remove secscope/debian-bookworm
```

### إعادة بناء كاملة من الصفر
```bash
./setup.sh destroy
./setup.sh
```
