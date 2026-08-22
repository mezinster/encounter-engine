<!-- Machine-translated from en.md on 2026-08-22. Not reviewed by a native speaker. -->

# Kullanıcı kılavuzu

encounter-engine nasıl kullanılır. Her biri bir rol için olmak üzere üç bölüm:

- **[Oyuncular için](#oyuncular-için)** — oyunlara katılırsınız.
- **[Oyun yazarları için](#oyun-yazarları-için)** — oyun oluşturur ve yürütürsünüz.
- **[Yöneticiler için](#yöneticiler-için)** — sunucunun tamamıyla ilgilenirsiniz.

Roller birbirinin üstüne biner: oyun yazarı, bir oyun oluşturmuş sıradan bir
oyuncudur. Bunun için ayrıca kaydolmanız gereken bir şey yoktur.

Rusça sürümü: [ru.md](ru.md). Kendi sunucunuzu çalıştırma: [deployment.en.md](deployment.en.md).

---

## Genel

### Kaydolma ve giriş

Sol menüdeki «Kaydol» ile kaydolun (`/signup`). Gereken tek şey **bir takma ad ile bir
e-posta adresidir**: parolayı siz seçmezsiniz, sunucu bir parola üretip size e-postayla
gönderir. Takma adınızı diğer oyuncular görür; e-posta adresinizi sunucu yöneticisi
dışında kimse görmez.

Kaydolur kaydolmaz oturumunuz açılır. Profilinizden **size gönderilen parolayı kendi
seçtiğiniz bir parolayla değiştirin** — gelen e-posta da bunu rica eder. Bu parola özü
gereği geçicidir, gerçi süresini dolduran bir şey yoktur.

Oturumu «Giriş yap» ile açarsınız (`/login`), «Çıkış yap» ile kapatırsınız.

**Unutulan parolalar** — giriş sayfasındaki «Parolanızı mı unuttunuz?» bağlantısı.
Verdiğiniz adrese süresi sınırlı bir bağlantı gönderilir ve yeni parolayı bu bağlantı
belirler. Adres kayıtlı olsa da olmasa da sunucu aynı yanıtı verir, dolayısıyla bu form
kimin kayıtlı olduğunu öğrenmek için kullanılamaz.

Kayıtlar ve parola sıfırlama istekleri IP adresi başına sınırlandırılmıştır. Ortak bir
Wi-Fi ağındayken «Çok fazla deneme» uyarısını alırsanız biraz bekleyip yeniden deneyin.

### Profil

Sol menüdeki «Profil». Burada duranlar:

- **takma adınız** — diğer oyuncuların sizi gördüğü ad;
- **iletişim bilgileri** — telefon, Instagram, Telegram, hangi mesajlaşma
  uygulamalarında bulunduğunuz (Telegram, WhatsApp, Viber, Signal, MAX) ve doğum
  tarihiniz. Hepsi isteğe bağlıdır. Bunları yalnızca sunucu yöneticisi görebilir —
  diğer oyunculara hiçbir zaman gösterilmez;
- **arayüz dili** — aşağıya bakın;
- **saat dilimi** — aşağıya bakın;
- **parola değiştirme** — yeni parola, doğrulaması ve **mevcut parolanız**. Mevcut
  parola girilmeden değişiklik kabul edilmez: aksi hâlde kilitlenmemiş bir tarayıcıya
  ulaşan herkes hesabı kalıcı olarak ele geçirebilirdi.

### Saat dilimi

Profilinizden kendi saat diliminizi seçebilirsiniz. Bundan sonra her tarih ve saat —
oyunun başlangıcı, bitiş süreleri, günlük kayıtları — sunucunun saat dilimi yerine
sizinkinde gösterilir. Boş bırakırsanız sunucunun saat dilimi kullanılır.

Saatin önem taşıdığı ekranlar (günlükler, sonuçlar) hangi saat dilimini kullandıklarını
yazar: «Saatler … saat diliminde gösterilmiştir». Böylece kimin saatini okuduğunuzu
tahmin etmek zorunda kalmazsınız.

### Arayüz dili

Dil değiştirici sayfa başlığındadır. Rusça, İngilizce, Ukraynaca, Gürcüce, Türkçe,
Belarusça ve Lehçe kullanılabilir.

Oturumunuz açıkken seçiminiz profilinize kaydedilir ve cihazdan cihaza sizinle gelir.
Tek seferlik bir değişiklik için adresin sonuna `?locale=en` ekleyin — bu, hem
profilinizi hem de sunucunun varsayılanını geçersiz kılar.

**Önemli:** değiştirici yalnızca arayüzü değiştirir — menüleri, düğmeleri, sistem
iletilerini. Görev metinleri, oyun adları ve açıklamaları yazarın kaleminden çıkar ve
her zaman yazıldığı gibi gösterilir. Çok dilli oyunlarda görevlerin dili için ayrı bir
değiştirici vardır — bkz. [Görevlerin dili](#görevlerin-dili).

Yanında bir «Tema» düğmesi vardır; açık ve koyu görünüm arasında geçiş yapar.

---

## Oyuncular için

### Takımınız

Oyunlar takım hâlinde oynanır. Bir takıma girmeden oynayamazsınız.

Takıma girmenin üç yolu vardır:

**Kendi takımınızı kurun.** Sol menüdeki «Takım oluştur». Takımı kuran kişi kaptan olur.

**Bir daveti kabul edin.** Bir kaptan sizi takma adınızla davet eder. Davet kişisel
panelinizde belirir; oradan kabul edebilir ya da reddedebilirsiniz.

**Katılmak için başvurun.** «Takımlar» sayfası (`/teams`) hepsini listeler; her birinin
yanında bir «Katılma başvurusu gönder» düğmesi bulunur. Başvurunuz kaptanın takım
odasına düşer, kabul ya da ret kararını kaptan verir.

### Takım odası

Sol menüdeki «Takım odası» — kadro, katılma başvuruları (kaptan için) ve takımla
yapılabilecek her şey:

| İşlem | Kim yapabilir |
|---|---|
| Üye davet etmek | kaptan |
| Katılma başvurusunu kabul etmek/reddetmek | kaptan |
| Kaptanlığı devretmek | takımda başka biri varsa, kaptan |
| Takımdan ayrılmak | her üye; kaptanın önce kaptanlığı devretmesi ya da takımda kalan son kişi olması gerekir |

Kaptanın diğer üyelerden üç farkı vardır: bir oyuna yalnızca kaptan başvurabilir,
takımı oyunun ortasında yarıştan yalnızca kaptan çekebilir ve kadroyu yalnızca kaptan
yönetir.

> **Takım yarıştayken kadro dondurulur.** Kimse takımdan ayrılamaz, kaptanlığı
> devredemez, başka bir takıma başvuramaz ya da başka bir takıma kabul edilemez. Aksi
> hâlde süren bir geçiş sahipsiz kalırdı.

### Bir oyuna başvurma

Sol menüdeki «Alan adındaki tüm oyunlar» hepsini listeler. Bir oyunun sayfasında
açıklama, başlangıç zamanı, son kayıt tarihi ve en fazla takım sayısı yer alır.

Başvuruyu kaptan, oyunun sayfasından gönderir. Başvuru sonra şu durumlardan geçer:

| Durum | Anlamı |
|---|---|
| Yeni | Gönderildi, yazar henüz yanıtlamadı |
| Kabul edildi | Takım oyuna girdi |
| Reddedildi | Yazar başvuruyu geri çevirdi |
| Geri çekildi | Yazar yanıtlamadan önce kaptan başvuruyu geri çekti |
| İptal edildi | Başvuru kabul edildikten sonra kaptan katılmaktan vazgeçti |

Başvurunuz soyut anlamda «oyuna» değil, oyunun güncel **koşusuna** yapılır — bkz.
sonraki bölüm.

### Koşular

Aynı oyun birden fazla kez sahneye konabilir — cumartesi bir kez, pazar bir kez daha ya
da altı ay sonra yeni bir kalabalık için. Bu çıkışların her birine **koşu** denir.

Bunun bir oyuncu açısından anlamı şudur:

- **her koşunun kendi başlangıç zamanı, son kayıt tarihi ve takım sınırı vardır.** Bir
  oyunun sayfasında güncel koşu gösterilir: başvuru alan koşu ya da sürmekte olan koşu;
- **sonuçlar ve günlükler koşu içinde sayılır.** Sıralamanız, oyunu bugüne dek oynamış
  herkesin arasında değil, sizinle birlikte koşan takımların arasındadır;
- birden fazla koşu yapılmışsa sonuç ve günlük sayfalarında bir «Koşular:» değiştiricisi
  belirir; böylece önceki bir koşunun nasıl geçtiğine bakabilirsiniz.

Yeni koşuları sunucu yöneticisi açar, üstelik ancak bir önceki koşu bittikten sonra.

### Oyunu oynama

Oyun, belirlenen saatte başlar. O saate kadar oyun sayfası sizi içeri almaz — bu
beklenen bir durumdur.

Oynamak için: oyunun sayfasından ya da doğrudan `/play/OYUN_NUMARASI` adresinden.

Görev sayfasında şunlar bulunur:

- **görev metni** — neyin bulunacağı ya da yapılacağı;
- **bir «Kod» alanı** — bulduğunuz kodu buraya girersiniz. Seçenekli görevlerde bunun
  yerine seçim yapacağınız bir liste çıkar;
- **ipuçları** — bunlar kendiliğinden belirir; sayaç, takımınız göreve ulaştığı anda
  çalışmaya başlar. Bir geri sayım, sonraki ipucuna kalan süreyi gösterir;
- **kod sayacı**, görevde birden fazla kod varsa ve hepsinin bulunması gerekiyorsa;
- **fotoğraflar**, yazar eklemişse — görev metninin altında bir küçük resim şeridi,
  beliren her ipucunun altında da bir şerit daha.

Cevap çubuğu — giriş alanı, sonraki ipucuna kalan geri sayım ve varsa biriken cezanız —
ekranın altına yapışır ve sayfayı nereye kaydırırsanız kaydırın orada kalır. Geri kalan
her şey sıradan bir sayfa kaydırmasıdır: görev metni, fotoğraflar, beliren her ipucu ve
cevap seçenekleri çubuğun üstünde durur; uzun bir görev de kaydırılarak okunur.

Bir fotoğrafa dokunduğunuzda tam boyutta açılır. PDF dosyaları ile hareketli GIF'ler
küçük resim yerine bir ataç simgesi ve dosya adı gösterir; onlar da aynı şekilde açılır.

Kodlar karşılaştırılırken büyük-küçük harf farkı ile baştaki ve sondaki boşluklar
dikkate alınmaz. Tek bir kodun kabul edilen birden fazla yazımı olabilir — buna yazar
karar verir.

**Bir görevin kaç kod gerektirdiğine yazar karar verir.** Birden fazla kodu olan bir
görev iki kipten birinde çalışır: «Kodlardan herhangi biri yeterli» ya da «Tüm kodların
bulunması gerekir». İkincisinde bir sayaç görürsünüz: «Girilen doğru kod sayısı: M
kodun N tanesi». Varsayılan, kodlardan herhangi birinin yeterli olmasıdır.

Kodları yalnızca kaptan değil, takımın her üyesi girebilir. İlerleme ortaktır.

### Seçenekli görevler

Bir görev kod istemek yerine seçim sunabilir — o zaman metin alanı yerine bir liste
görürsünüz ve bazı görevlerde birden fazla seçenek doğrudur.

**Yanlış seçimin bir cezası olabilir**; yazar bu cezayı dakika olarak belirler. Ceza,
görevde geçirdiğiniz süreyi yemez ve ipuçlarını yaklaştırmaz: bitişte toplam sürenize
eklenir. Ceza **her seferinde** işlenir, daha önce denediğiniz bir seçeneği yeniden
seçtiğinizde de — aksi hâlde bir takım tek bir hatanın bedeliyle bütün seçenekleri tek
tek dolaşabilirdi.

Biriken cezanız, ortaya çıktığı anda görev sayfasında gösterilir.

Yanlış yazılan bir **kod** için ceza yoktur — ceza yalnızca seçenekli görevlerde vardır.

### Görevlerin dili

Oyun çok dilliyse görev sayfasında görev içeriği için ayrı bir dil değiştirici bulunur.
Bu, arayüz dilinden bağımsızdır: arayüzünüz Türkçe iken görevler Rusça olabilir.

Belirli bir görev seçtiğiniz dile henüz çevrilmemişse, özgün metin bunu belirten bir
notla birlikte gösterilir. Metnin yerine hiçbir zaman makine çevirisi konmaz.

### Duraklamalar

Düzenleyici oyunu duraklatabilir — diyelim ki sağanak yağış ya da trafiğe kapatılmış bir
sokak yüzünden. O zaman görevinizin üstünde bir ileti belirir.

Oyun duraklatılmışken:

- **ipucu sayaçları durur.** Yeni ipucu belirmez ve duraklama sizin süre hakkınızdan
  yemez — oyun devam ettiğinde geri sayım tam kaldığı yerden sürer;
- **kodlar kabul edilmez** ve giriş alanı tamamen kaldırılır;
- görev görünür kalır, böylece üzerinde düşünmeyi sürdürebilirsiniz.

Yerinizde kalın ve oyunun devam etmesini bekleyin.

### Oyundan çekilme

Kaptan, «Yarıştan çekil» ile takımı oyundan çıkarabilir.

**Bu tek yönlüdür: takım kendini oyuna geri alamaz.** Sizi ancak oyunun yazarı ya da bir
sunucu yöneticisi oyuna geri alabilir — yanlışlıkla tıklandıysa onlara başvurun.

### Sonuçlar

Bir takım oyunu bitirdiğinde koşunun tablosunu görür: sıra, takım, bitiş zamanı, ceza ve
toplam.

**Sıralama, bitiş zamanına göre değil toplama göre yapılır.** Seçenekli görevlerde ceza
toplamış bir takım, daha uzun sürede bitiren ama hiç hata yapmayan bir takımın altında
yer alır.

Oyunun tamamına ait tam cevap günlüğü, oyunu **bitiren** takımlara (yarıştan çekilen
takımlara değil) ve oyunun yazarına açıktır. Birden fazla koşu yapılmışsa en üstte bir
koşu değiştiricisi bulunur.

---

## Oyun yazarları için

### Oyun oluşturma

Kişisel panelinizdeki «Oyun oluştur >>». Bir ad, bir açıklama, bir başlangıç zamanı, bir
son kayıt tarihi ve en fazla takım sayısı gerekecektir.

Asıl önemli olan **«Taslak mı?»** kutusudur:

- **taslak** yalnızca sizin görebildiğiniz durumdur; böylece her şeyi rahat rahat
  hazırlarsınız;
- **kutunun işaretini kaldırdığınızda oyun yayımlanır**, herkese görünür olur ve
  başvurulara açılır.

Yayımlanmış bir oyun, başladıktan sonra düzenlenemez.

Başlangıç zamanı, son kayıt tarihi ve takım sınırı oyunun güncel **koşusuna** aittir.
Çoğu oyunda olduğu gibi tek bir koşu varken aradaki farkı fark etmezsiniz: form aynı
formdur.

### Görevler, kodlar ve ipuçları

Görevler oyunun sayfasından eklenir («Yeni görev ekle»). Sıralamayı oklarla
değiştirirsiniz.

Bir görevin şunları vardır:

- **bir ad ve bir metin** — oyuncunun gördüğü şey;
- **kodlar** — doğru cevaplar. Her kodun kabul edilen birden fazla yazımı olabilir;
  bunlar eşdeğer sayılır;
- **kodların nasıl sayılacağı** — birden fazla kodu olan görevler için: «Kodlardan
  herhangi biri yeterli» (varsayılan) ya da «Tüm kodların bulunması gerekir»;
- **seçenekler** — oyuncunun kod yazmak yerine listeden seçmesini istiyorsanız (aşağıya
  bakın);
- **yanlış cevap cezası**, dakika olarak; yalnızca seçenekli görevlerde işler;
- **ipuçları** — her biri, takımın göreve ulaştığı andan sayılan dakika cinsinden bir
  gecikmeyle.

İpuçları, oyunun temposunu ayarlayan asıl araçtır. Bir görevde takılan takım ipuçlarını
arka arkaya alır; ilerlemiş olan takım hiç almaz.

### Seçenekler

Görevin sayfasındaki «Cevap seçenekleri». Bir kodun seçenekleri olduğunda oyuncular
yazmak yerine listeden seçer. Birden fazla seçenek doğru olabilir — o zaman yalnızca tam
olarak doğru küme sayılır: burada «kısmen doğru» diye bir şey yoktur, çünkü bu oyunda
puan süredir.

Yanlış seçimin cezası görevin kendisinde dakika olarak belirlenir ve takımın toplam
süresine eklenir.

### Dosyalar ve görseller

Bir göreve ya da ipucuna fotoğraf eklenebilir — kodun yazılı olduğu levha, bulunacak
bina, harita parçası.

**Bir kez yükleyin, defalarca ekleyin.** Dosyalar göreve değil oyuna aittir. Oyunun
sayfasındaki «Dosyalar», oyunun kütüphanesidir: dosyaları oraya yükleyin, sonra herhangi
bir görev ya da ipucu formunda «Oyun kütüphanesi» listesinden seçerek ekleyin. Aynı
fotoğraf, yeniden yüklenmeden ve kotadan iki kez düşülmeden birden fazla göreve
asılabilir.

**Neler yükleyebilirsiniz.** Varsayılan olarak JPEG, PNG, GIF, HEIC ve PDF. Varsayılan
sınırlar **dosya başına 25 MB**, **yükleme başına 10 dosya** ve **oyun başına 100
MB**'dir — bir yönetici üçünü de ayarlar ekranından değiştirebilir, bu yüzden bunları
değişmez kurallar değil, o anki değerler olarak görün. Oyunun «Dosyalar» sayfası nerede
durduğunuzu gösterir: «Y MB'nin X MB'si kullanıldı». Görüntülerde ayrıca 50
megapiksellik bir üst sınır vardır; hiçbir telefon kamerası buna yaklaşmaz.

**HEIC dosyaları sizin için dönüştürülür.** iPhone'dan gelen fotoğraflar HEIC
biçimindedir; yükleme sırasında geri çevrilmek yerine yeniden kodlanır.

**Dosyanın türü, adına değil baytlarının okunmasına göre belirlenir.**
Bir `dosya.exe` dosyasının adını `dosya.jpg` olarak değiştirmek onu içeri sokmaz.

**Fotoğraflardan konum bilgisi silinir.** JPEG, PNG ve HEIC görüntüleri çözülür ve EXIF
ile GPS dâhil her üst veri alanı atılarak yeniden yazılır — bu, çoğu uygulamadakinden
daha önemlidir, çünkü «şu binayı bulun» türünden bir görevde fotoğraftaki koordinatlar
cevabın *ta kendisidir*. Bir istisnaya dikkat edin: GIF ve PDF dosyaları denetlenir ama
yeniden kodlanmaz, dolayısıyla içlerindeki üst veriler olduğu gibi kalır. Üst verisine
bakmadığınız hiçbir şeyi PDF olarak kullanmayın.

**Ekler dile göredir.** Çok dilli bir oyunda her dil sekmesinin kendi dosya kümesi
vardır; ana dil sekmesi ise dilden bağımsız kümeyi tutar. Bir oyuncu, dilden bağımsız
dosyaları **artı** okuduğu dile ait olanları görür — önce dilden bağımsız olanları. Yani
çeviri gerektirmeyen bir fotoğraf ana dil sekmesine konur ve herkese görünür; iki dilde
fotoğraflanmış bir tabela ise iki dil sekmesine ayrı ayrı konur.

**Oyuncuların gördüğü:** görev metninin altında kare küçük resimlerden oluşan bir şerit,
beliren her ipucunun altında da bir şerit daha — hiçbir zaman metnin içinde değil.
Birine dokunmak dosyayı tam boyutta açar. PDF dosyaları ile hareketli GIF'ler küçük
resim yerine bir ataç simgesi ve dosya adı gösterir.

**Silme.** Dosyalar oyunun «Dosyalar» sayfasından silinir; sayfa hangilerinin
«kullanılmıyor» olduğunu işaretler. Oyun sürerken silme işlemi önce dosyanın adını
yazmanızı ister — bu, bilerek konmuş bir engeldir, çünkü yarışın ortasında kaldırılan
bir dosya, sokakta duran takımların ayağının altından çekilmiş olur.

Bir dosyanın saklanan verisi kaybolursa yalnızca o görüntü 404 verir; görev ve metni
yine de görüntülenir.

### Görevleri toplu aktarma

Oyunun sayfasındaki «Toplu seviye aktarımı», yirmi otuz görevi tek tek elle girmekten
kurtarır. Hepsini birden yapıştırın: bir satır (ya da arka arkaya birkaç satır) görev
metnidir, ardından cevaplar gelir.

```
Kievskaya ile Çuy köşesine kadar yürüyün.
Binanın duvarında yapım yılını veren bir levha var.
A) 1967

Belarus'un başkenti hangi şehirdir?
A) Brest
B) Grodno
C) *Minsk
```

- `A) KOD` biçiminde tek bir cevap — kodlu sıradan bir görev;
- iki ya da daha fazla cevap — seçenekli bir görev; doğru olanı yıldızla işaretleyin,
  birden fazla cevap doğruysa iki yıldız kullanın;
- **«harf) metin» biçimindeki bir satır her zaman cevap olarak okunur**, görevin
  ortasında bile. Görev metni böyle bir satırla başlayamaz.

Hiçbir şey eklenmeden önce bir önizleme görürsünüz: neler eklenecek ve neler zaten var
olduğu için atlandı. Başlamış bir oyuna aktarım yapılamaz.

### Çok dilli oyunlar

Bir oyunun bir ana dili ve sunulduğu dillerin listesi vardır. Bunun ardından düzenleme
ekranında, bildirilen her dil için bir sekme belirir. Seçenekler ayrıca, liste hâlinde,
seçenekler sayfasından çevrilir.

Kodlar tüm diller için ortaktır. Bir cevap başka bir dilde farklı yazılıyorsa her yazımı
ayrı bir doğru kod olarak ekleyin.

Ekli dosyalar da dile göredir ve birbirinin yerini almak yerine üst üste eklenir — bkz.
[Dosyalar ve görseller](#dosyalar-ve-görseller).

İki kural:

1. **Çevirisi tamamlanmamış bir oyun yayımlanamaz.** Oyun Rusça ile İngilizceyi
   bildiriyorsa ve bir alan çevrilmemişse yayımlama reddedilir ve tam olarak hangi
   alanların eksik olduğu size gösterilir.
2. **Çeviriler var olduktan sonra ana dil değiştirilemez** — aksi hâlde metin sütunları
   hâlâ bir dili tutarken oyun başka bir dil bildiriyor olurdu.

### Başvurular

Başvurular oyunun sayfasında görünür. Her birini kabul edin ya da reddedin. Kabul edilen
takım sayısı, güncel koşu için belirlediğiniz üst sınırı aşamaz.

### Test etme

**«Testi başlat»** oyunu test kipine alır: oyun hemen başlar ve onu kendiniz
oynayabilirsiniz — test kipinde yazarın kendi oyununa girmesine izin verilir.

**«Testi bitir»** oyunu taslak durumuna döndürür ve özgün başlangıç tarihini geri
getirir.

> **Dikkat:** testi bitirmek, o oyuna ait **bütün geçişleri ve günlükleri siler**. Amaç
> da budur — asıl oyundan önce testin izlerini temizler. Gerçekten oynanmış bir oyunda
> bu düğmeye basmayın.

Test başlamıyorsa nedeni size bildirilir — çoğu zaman neden, tamamlanmamış bir çeviridir.

### Oyunu izleme

Oyun listesinde, kendi oyununuzun yanında:

| Bağlantı | Neyi gösterir |
|---|---|
| (istatistik) | Her takımın hangi görevde olduğunu ve orada ne kadar süredir beklediğini |
| (canlı yayın) | Oyun boyunca girilen her kodu, girildiği anda |
| (cevap günlüğü) | Tüm takımların ve tüm görevlerin yer aldığı eksiksiz günlüğü |

İstatistik sayfası, oyun sırasındaki ana ekrandır. Müdahaleler de oradadır.

Üç ekran da oyunun ve koşunun adını verir, kaç takımın ve kaç görevin işin içinde
olduğunu gösterir ve saatlerin hangi saat diliminde olduğunu yazar. Tam günlük sayfalara
bölünmüştür. Birden fazla koşu yapılmışsa en üstteki «Koşular:» değiştiricisi sizi
önceki koşuya götürür.

### Süren bir oyuna müdahale

Kendi oyununuzun istatistik sayfasından şunları yapabilirsiniz:

**Oyunu duraklatmak / sürdürmek.** Duraklama, her takımın ipucu sayacını durdurur ve
kodları kabul etmez. Oyunu sürdürdüğünüzde her takım kalan süresini olduğu gibi geri
alır. Fırtınalarda, acil durumlarda, kapanmış bir sokak yüzünden kullanın.

**Bir takımı başka bir göreve taşımak.** Bozulmuş bir görevde takılan takımlar için: kod
tutmuyor, konuma ulaşılamıyor. Yeni görevin ipucu sayacı baştan başlar ve mevcut görevde
girilmiş kodlar silinir.

**Bir takımı oyuna geri almak.** Kaptan yanlışlıkla tıkladığında «Yarıştan çekil»
işlemini geri alır. İpucu sayacı baştan başlar.

**Süre sayacını sıfırlamak.** İpuçları yanlış anda çıktıysa görevdeki süreyi sıfırlar.

**Bir görevde kodların nasıl sayıldığını değiştirmek** — «Herhangi biri yeterli» /
«Tümü gerekli». Bu, konumlardan birinin ulaşılamaz çıktığı çok kodlu bir görevi
kurtarır: her takımla tek tek uğraşmak yerine görevin kendisini herkes için birden
yumuşatırsınız.

Bunların hepsi oyun sürerken işler, oyun duraklatılmışken de. Cevap geçmişini
(günlükleri) hiçbir müdahale değiştirmez — günlük, takımın gerçekte ne girdiğinin
dürüst kaydı olarak kalır.

### Oyunu bitirme

**«OYUNU BİTİR»** oyunu bütün takımlar için aynı anda bitirir.

**Bu geri alınamaz** — hiçbir takım başka bir kod giremez. Oyun gerçekten bittiğinde
kullanın.

Bitmiş bir oyun yeniden sahneye konabilir: bir sunucu yöneticisi yeni bir koşu açar ve
kayıtlar baştan başlar. Görevler, kodlar ve ipuçları olduğu gibi kalır; önceki koşunun
sonuçları ise ayrı olarak saklanır.

Yanlışlıkla bitirilmiş bir oyunu bir yönetici yeniden başlatabilir.

### Yazarlığı devretme

Oyunun sayfasındaki «Yazarlığın devri» — yeni yazarın takma adını girin. Oyun bütünüyle
onun olur: düzenlemeyi o yapar, başvurulara o karar verir, müdahaleleri o yürütür.

Oyun sürerken ya da düzenleme bir yönetici tarafından dondurulmuşken yazarlık
devredilemez.

### Oyunu silme

Bir oyun **ancak henüz kimse oynamamışsa** silinebilir. Tek bir geçiş bile varsa silme
reddedilir: aksi hâlde takımların günlükleri ve sonuçları boşluğu gösterir kalırdı.

Oynanmış bir oyun için silme yerine yayından kaldırma vardır — bir yöneticiye başvurun.

---

## Yöneticiler için

Sunucu yöneticisi (superadmin), yalnızca kendi oyunlarından değil, sunucudaki bütün
oyunlardan sorumludur.

Yetkileri başka bir yönetici verir. İlk yönetici ise sunucu konsolundan atanır — aksi
hâlde yetkiyi verecek kimse olmazdı (bkz.
[kurulum kılavuzu](deployment.en.md#6-the-first-administrator)).

### Neler nerede

Yetkileri aldığınızda sol menüde bir **Yönetim** bölümü belirir:

| Öğe | Adres | Orada ne var |
|---|---|---|
| Genel bakış | `/admin` | Özet: duruma göre oyunlar, oyuncu/takım/oyun toplamları, başvurular |
| Tüm oyunlar | `/admin/games` | Sunucudaki her oyun, işlemleriyle birlikte |
| Oyuncular | `/admin/users` | Kayıtlı olan herkes |
| İşlem günlüğü | `/admin/audit` | Kim ne yapmış |

Genel bakış sayfasından iki bağlantı daha verilir: **Tüm takımlar** (`/admin/teams`) ve
**Sınırlama ayarları** (`/admin/settings`).

### Diğer oyuncuların yetkileri

Bir oyuncunun sayfasında (`/admin/users/NUMARA`) «Yönetici yap» ve «Yönetici yetkilerini
al» bulunur.

İki sınır vardır ve ikisi de kaldırılamaz:

- **kendi yetkilerinizi geri alamazsınız** — bu, yanlışlıkla kendinizi kapının dışında
  bırakmanıza karşı bir korumadır ve her yetki düşürmenin günlükte ikinci bir tarafı
  olmasını güvence altına alır;
- **son yöneticinin yetkilerini geri alamazsınız** — sunucu hiçbir zaman yöneticisiz
  kalmamalıdır. Bu kural konsolda da geçerlidir.

Bir oyuncunun sayfası iletişim bilgilerini gösterir — telefon, Instagram, Telegram,
mesajlaşma uygulamaları, doğum tarihi. Bunlar listede bilerek yer almaz: birinin
iletişim bilgilerini görmek, o kişinin sayfasına bilinçli olarak gitmeyi gerektirir.

### Oyunculara yönelik işlemler

Aynı sayfadan:

**Bir takıma taşımak.** Kişinin kendi kendine taşınamadığı durumlar için — kaptan
ortadan kaybolmuş ve takım dağılmıştır.

**Hesabı silmek.** Kalıcı olarak. Kendinizi, son yöneticiyi, bir kaptanı (önce takımına
başka bir kaptan atayın) ya da **oyun yazarı olan birini** silemezsiniz — bu sonuncusu,
başkalarının oynadığı oyunları ortadan kaldırırdı.

**Hesabı anonimleştirmek.** Bir yazarı silmek yerine yapılan işlem budur: kişi
listelerden ve görünürden kaybolur, oyunları ise yerinde kalır.

Takımlardan biri — ayrıldığı takım ya da katıldığı takım — yarıştayken bir oyuncu
taşınamaz.

### Takımlara yönelik işlemler

`/admin/teams` sayfasından: **kaptan atamak** (bir öncekinin ortadan kaybolduğu ve
kaptanlığı devredecek kimsenin kalmadığı durumlarda) ve **takımı silmek** — yalnızca boş
olan ve hiç oynamamış bir takımı.

### Oyunlara yönelik işlemler

`/admin/games` sayfasından:

**Yayından kaldırmak / Yayımlamak.** Oyunu herkese açık listelerden çıkarır ve dışarıya
kapatır. Yazar ile yöneticiler oyunu görmeyi sürdürür.

> **Hâlihazırda oynayan** takımlar oyunu sürdürür — yayından kaldırmak, insanları
> şehrin ortasında yarıştan atmaz. Bu bilinçli bir tercihtir.

**Dondurmak / Çözmek.** Yazar artık oyunu düzenleyemez, testi başlatıp bitiremez, oyunu
silemez, bitiremez ve yazarlığı devredemez. Ne olduğunu tespit etmeniz ve durumu olduğu
gibi tutmanız gerektiğinde kullanın.

Dondurma, yazarın oyununa ve günlüklerine **bakmasını** engellemez — yalnızca
değiştirmesini engeller. Yöneticileri ise hiç kısıtlamaz.

**Yeniden başlatmak.** Yazar «OYUNU BİTİR» düğmesine çok erken bastığında oyunu bitirme
işlemini geri alır.

**Yazarı değiştirmek.** Mevcut yazara sorulmadan yapılan yazarlık devri — yazara
ulaşılamadığı ya da yazarın istekli olmadığı durumlar için. Yazarın kendi devrinden
farklı olarak bu işlem, dondurulmuş bir oyunda da süren bir oyunda da işler.

**Yeni koşu açmak.** Aynı oyunu yeniden sahneye koymak — aşağıya bakın.

**Başvurular (N).** Takım kabul konsolu — aşağıya bakın.

**Silmek.** Kural yazardaki ile aynıdır: yalnızca kimse oynamamışsa. Aksi hâlde yayından
kaldırın.

### Yeni bir koşu

`/admin/games` sayfasındaki «Yeni koşu aç» — başlangıç zamanı, son kayıt tarihi ve takım
sınırı içeren bir form. Bunun ardından oyun yeniden başvuru alır; önceki sonuçlar ise
kendi koşu numaralarının altında yerlerinde kalır.

İki koşul:

- **önceki koşunun bitmiş olması gerekir.** Süren bir koşunun üstüne yeni koşu açılamaz;
- **oyunda en az bir görev bulunması gerekir.**

Başlangıç zamanının gelecekte, son kayıt tarihinin de ondan önce olması gerekir.

### Bir oyunun başvuruları

`/admin/games` sayfasında bir oyunun yanındaki «Başvurular (N)» — güncel koşuya kimlerin
başvurduğunu gösteren ve yazar olmadan kabul ya da ret verebileceğiniz bir ekran.

Bu, yazara ulaşılamadığı ve oyunun başlamak üzere olduğu durumlar içindir: eskiden bir
yöneticinin yazarlığı bütünüyle devralması gerekirdi.

Ekran yalnızca güncel koşunun başvurularını gösterir ve bunun hangi koşu olduğunu yazar.

### Sınırlama ayarları

`/admin/settings` — tek bir IP adresinin belirli bir süre içinde kaç kayıt ve kaç parola
sıfırlama isteği yapabileceği. `0` bir sınırlamayı kapatır.

Varsayılan değerler sıradan bir sunucuya uygundur. Bu değerleri yükseltmek nadiren
gerekir; düşürmek ise birinin kapıyı yumrukladığı durumlar içindir. Tek bir adresin koca
bir kulüp ya da koca bir yurt olabileceğini unutmayın.

### Depolama

`/admin` sayfası **Depolama** bilgisini gösterir: sunucunun tuttuğu yüklenmiş dosyaların
kaç megabayt olduğunu ve üst sınırın ne kadar olduğunu.

Sınırlar `/admin/settings` sayfasındadır; hepsi değiştirebileceğiniz varsayılan
değerlerdir:

| Ayar | Varsayılan | Ne işe yarar |
|---|---|---|
| Maksimum dosya boyutu (MB) | 25 | Yükleme sırasında, dosya başına |
| Yükleme başına dosya sayısı | 10 | Bir seferde kaç dosya |
| Oyun başına kota (MB) | 100 | Oyun başına; özgün dosyaları ve üretilen önizlemeleri sayar |
| Sunucu genelinde toplam sınır (MB) | 4096 | Bütün oyunlar için toplam |
| Diskte korunacak minimum boş alan (MB) | 3072 | Bunun altında yüklemeler reddedilir |
| İzin verilen dosya uzantıları | `jpg jpeg png gif heic pdf` | Daraltılabilir, hiçbir zaman genişletilemez |

Bunlardan ikisi hakkında bir iki söz gerekir.

**Boş alan alt sınırı bir muhasebeci değil, bir frendir.** *Disk* azaldığında, kimin ne
kadar kotası kaldığına bakmadan yüklemeleri reddeder. Tek ve küçük bir sunucuda bunun
alternatifi, diski doldurup yüklemelerle birlikte veritabanını ve bir sonraki dağıtımı
da devirmektir.

**Uzantı listesi yalnızca daraltılabilir.** Kullanılmadan önce sabit bir iç listeyle
kesiştirilir; bu yüzden `pdf` uzantısını çıkarmak işe yarar, `svg` eklemek ise hiçbir
şey yapmaz — bu bilinçlidir, çünkü listeden çıkarılan biçimler çalıştırılabilir içerik
taşıyabilen biçimlerdir.

Dosyaların artık kullanmadığı alanı geri kazanmak bir düğme değil, sunucu tarafında
yapılan bir işlemdir — kurulum kılavuzundaki
[dosya deposunu geri kazanma](deployment.en.md#9-reclaiming-file-storage) bölümüne bakın.

### Başkalarının oyunlarına müdahale

[Süren bir oyuna müdahale](#süren-bir-oyuna-müdahale) bölümündeki her şey, bir
yöneticinin yalnızca kendi oyununda değil **her** oyunda elinin altındadır: duraklatma,
takımı taşıma, takımı oyuna geri alma, süre sayacını sıfırlama, görevin kod kuralını
yumuşatma.

Yetkiler zaten bunun içindir: bir takım şehrin ortasında beklerken yazara ulaşılamıyor
olabilir.

### Yönetici işlemleri günlüğü

`/admin/audit` — kim, ne, ne zaman ve hangi nesne üzerinde.

**Günlüğe yazılanlar:** bir yöneticinin **başkasının** oyunundaki işlemleri, oyuncular
ve takımlar üzerindeki işlemler, koşu açma, yazar değiştirme, ayar değiştirme ve yetki
verme ya da geri alma.

**Yazılmayanlar:**

- bir yazarın **kendi** oyunundaki işlemleri. Bu, yöneticilik değil sıradan iştir;
  bunları yazmak günlüğü rutine boğardı;
- görüntülemeler. Günlük «bunu kim değiştirdi» sorusunu yanıtlar, «buna kim baktı»
  sorusunu değil — bir oyuncunun iletişim bilgilerine bakmak da buna dâhildir;
- ilk yöneticinin konsoldan atanması. Bunun bir çaresi yoktur: günlüğü web uygulaması
  tutar, konsol ise onu atlar.

Günlük kayıtları **hiçbir zaman düzenlenmez ya da silinmez** — ne arayüzden ne de başka
bir yoldan. Konusu olan kişinin düzenleyebildiği bir günlük, günlük sayılmaz.

Bir oyunun adı ya da bir oyuncunun takma adı günlüğe **o andaki hâliyle** yazılır.
Böylece silinmiş bir oyunla ilgili kayıt, hiçbir yere götürmeyen bir numara göstermek
yerine oyunun adını vermeyi sürdürür.

---

## Bir şeyler ters gittiğinde

| Belirti | Ne anlama gelir |
|---|---|
| «Oyun düzenleyici tarafından duraklatıldı» | Bir duraklama. Bekleyin; ipuçları dondurulmuştur ve süre kaybetmezsiniz |
| Oyun sayfası başlangıçtan önce içeri almıyor | Oyun henüz başlamadı — bu normaldir |
| Parola gönderildi ama e-posta gelmedi | Gereksiz posta klasörüne bakın. «Parolanızı mı unuttunuz?» ile yenisini alabilirsiniz |
| Kaydolurken «Çok fazla deneme» | IP başına sınırlama. Bekleyin ya da bir yöneticiden sınırı yükseltmesini isteyin |
| Profil parolayı değiştirmiyor | Mevcut parolanız da gerekir — ödünç alınmış tarayıcıya karşı koruma budur |
| Takım yanlışlıkla yarıştan çekildi | Oyunun yazarı ya da bir yönetici takımı oyuna geri alabilir |
| Takımdan ayrılmak ya da kaptanlığı devretmek olmuyor | Takım yarıştadır. Kadro yarıştan sonra çözülür |
| Ekrandaki saatler kolunuzdaki saate uymuyor | Profilinizdeki saat dilimini gözden geçirin; günlük ekranları kullandıkları saat dilimini yazar |
| Test başlamıyor | Büyük olasılıkla çeviri tamamlanmamıştır — nedeni ekranda gösterilir |
| Oyun silinmiyor | Oyun oynanmıştır. Onun yerine yayından kaldırın |
| Yazar oyunu düzenleyemiyor | Ya oyun başlamıştır ya da düzenleme bir yönetici tarafından dondurulmuştur |
| Yeni koşu açılmıyor | Ya önceki koşu bitmemiştir ya da oyunda hiç görev yoktur |
| Beklenenden düşük bir sıra | Yanlış seçeneklerin cezaları bitiş süresine eklenir |
