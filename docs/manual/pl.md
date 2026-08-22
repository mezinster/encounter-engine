<!-- Machine-translated from ru.md on 2026-08-22. Not reviewed by a native speaker. -->

# Podręcznik użytkownika

Jak korzystać z encounter-engine. Trzy rozdziały — według ról:

- **[Dla graczy](#dla-graczy)** — bierzesz udział w grach.
- **[Dla autorów gry](#dla-autorów-gry)** — tworzysz gry i je prowadzisz.
- **[Dla administratorów](#dla-administratorów)** — odpowiadasz za cały serwer.

Role się sumują: autor gry to zwykły gracz, który stworzył grę. Nie trzeba osobno
zapisywać się na autora.

Wersja angielska: [en.md](en.md). Jak postawić własny serwer: [deployment.ru.md](deployment.ru.md).

---

## Ogólne

### Rejestracja i logowanie

Rejestracja — „Zarejestruj się” w lewym menu (`/signup`). Potrzebne są tylko **pseudonim i e-mail**:
hasła nie wymyślasz sam — generuje je serwer i wysyła e-mailem. Pseudonim widzą inni gracze,
adres e-mail — nie (poza administratorem serwera).

Zaraz po rejestracji jesteś już zalogowany. **Zmień przysłane hasło na swoje** — w profilu; e-mail
z hasłem właśnie o to prosi. Hasło z e-maila jest tymczasowe z założenia, ale samo w sobie nie
wygasa.

Logowanie — „Zaloguj się” (`/login`), wylogowanie — „Wyloguj się”.

**Zapomniane hasło** — link „Nie pamiętasz hasła?” na stronie logowania. Na podany adres przyjdzie
link ważny przez ograniczony czas; po jego otwarciu ustawiasz nowe hasło. Serwer odpowiada tak samo
niezależnie od tego, czy taki adres istnieje — po odpowiedzi nie da się sprawdzić, czy ktoś jest
zarejestrowany.

Rejestracji i próśb o reset hasła z jednego adresu można zrobić ograniczoną liczbę w danym
okresie. Jeśli natknąłeś się na komunikat „Zbyt wiele prób” na wspólnym Wi-Fi — poczekaj i spróbuj
ponownie.

### Profil

„Profil” w lewym menu. Co tu jest:

- **pseudonim** — pod nim widzą Cię inni;
- **kontakty** — telefon, Instagram, Telegram, zaznaczone komunikatory (Telegram, WhatsApp,
  Viber, Signal, MAX) i data urodzenia. Wszystkie opcjonalne. Widzi je tylko administrator
  serwera, innym graczom się ich nie pokazuje;
- **język interfejsu** — patrz niżej;
- **strefa czasowa** — patrz niżej;
- **zmiana hasła** — nowe hasło, jego potwierdzenie i **bieżące hasło**. Bez bieżącego hasła
  nowego nie przyjmie: inaczej każdy, kto dorwałby się do niezamkniętej przeglądarki, mógłby
  zmienić hasło na stałe.

### Strefa czasowa

W profilu można wybrać własną strefę czasową. Wtedy wszystkie daty i godziny — start gry, czas
mety, wpisy w dziennikach — pokazują się w niej, a nie w strefie serwera. Jeśli jej nie wybierzesz,
używana jest strefa serwera.

Ekrany, na których czas jest krytyczny (dzienniki, wyniki), są podpisane: „Czas podano w strefie
…” — żeby nie trzeba było zgadywać, czyj to czas.

### Język interfejsu

Przełącznik języka jest w nagłówku strony. Dostępne są: rosyjski, angielski, українська,
ქართული, Türkçe, беларуская i polski.

U zalogowanego użytkownika wybrany język zapamiętywany jest w profilu i obowiązuje na
wszystkich urządzeniach. Jednorazowo język można ustawić parametrem `?locale=en` w adresie — ma on
pierwszeństwo zarówno przed profilem, jak i przed ustawieniem serwera.

**Ważne:** przełącznik zmienia tylko interfejs — menu, przyciski, komunikaty systemowe. Teksty
zadań, nazwy i opisy gier pisze autor, i zawsze są pokazywane tak, jak on je napisał. W grach
wielojęzycznych język zadań przełącza się osobno — patrz [Język zadań](#język-zadań).

Obok jest przycisk „Motyw” — przełącza jasny i ciemny wygląd.

---

## Dla graczy

### Drużyna

Gra się drużynami. Dopóki nie należysz do drużyny, nie możesz grać.

Do drużyny można dołączyć na trzy sposoby:

**Utworzyć własną.** „Utwórz drużynę” w lewym menu. Osoba, która ją tworzy, zostaje kapitanem.

**Przyjąć zaproszenie.** Kapitan zaprasza Cię po pseudonimie. Zaproszenie pojawi się w panelu
gracza — możesz je przyjąć albo odrzucić.

**Poprosić samemu.** „Drużyny” (`/teams`) — lista drużyn, przy każdej przycisk „Złóż zgłoszenie
o przyjęcie”. Zgłoszenie trafia do kapitana do „Pokoju drużyny”, gdzie je przyjmuje albo odrzuca.

### Pokój drużyny

„Pokój drużyny” w lewym menu — skład, zgłoszenia o przyjęcie (u kapitana) i wszystko, co można
zrobić z drużyną:

| Działanie | Kto może |
|---|---|
| Zaprosić członków | kapitan |
| Przyjąć/odrzucić zgłoszenie o przyjęcie | kapitan |
| Przekazać kapitaństwo | kapitan, jeśli w drużynie jest ktoś jeszcze |
| Opuścić drużynę | dowolny członek; kapitan — tylko przekazując kapitaństwo albo zostając sam |

Kapitan różni się od pozostałych prawem do złożenia zgłoszenia do gry, prawem do rezygnacji z gry
i zarządzaniem składem.

> **Dopóki drużyna jest na trasie, skład jest zablokowany.** Nie można opuścić drużyny, przekazać
> kapitaństwa, złożyć zgłoszenia do innej drużyny ani przyjąć cudzego. Inaczej rozgrywka zostałaby
> bez gospodarza w środku gry.

### Zgłoszenie do gry

Lista gier — „Wszystkie gry domeny” w lewym menu. Na stronie gry widoczne są opis, data
rozpoczęcia, ostateczny termin zgłoszeń i maksymalna liczba drużyn.

Kapitan składa zgłoszenie ze strony gry. Dalej przechodzi ono przez statusy:

| Status | Co oznacza |
|---|---|
| Nowe | Złożone, autor jeszcze nie odpowiedział |
| Przyjęte | Drużyna dopuszczona do gry |
| Odrzucone | Autor odmówił |
| Wycofane | Kapitan wycofał zgłoszenie przed odpowiedzią autora |
| Anulowane | Kapitan zrezygnował z udziału już po przyjęciu zgłoszenia |

Zgłoszenie składa się nie „do gry w ogóle”, lecz do jej bieżącego **biegu** — patrz następny
rozdział.

### Biegi

Tę samą grę można rozegrać kilka razy — na przykład w sobotę i w niedzielę, albo pół roku
później dla nowych osób. Każde takie rozegranie nazywa się **biegiem**.

Co z tego wynika dla gracza:

- **każdy bieg ma własną datę rozpoczęcia, termin zgłoszeń i limit drużyn.** Strona gry pokazuje
  bieżący bieg — ten, na który właśnie trwają zapisy, albo który właśnie trwa;
- **wyniki i dzienniki liczone są w ramach biegu.** Twoje miejsce liczy się wśród tych, którzy
  biegli razem z Tobą, a nie wśród wszystkich, którzy kiedykolwiek przechodzili tę grę;
- jeśli biegów było kilka, na stronach wyników i dzienników pojawia się przełącznik „Biegi:” —
  można sprawdzić, jak wszystko przebiegło poprzednim razem.

Nowy bieg otwiera administrator serwera, i tylko po tym, jak poprzedni został zakończony.

### Jak przebiega gra

Gra zaczyna się o wyznaczonej godzinie. Do tego momentu strona gry nie wpuszcza — to normalne.

Gra: strona gry → link do gry, albo bezpośrednio `/play/NUMER_GRY`.

Na stronie zadania:

- **treść zadania** — co trzeba znaleźć albo zrobić;
- **pole „Kod”** — tu wpisuje się znaleziony kod. W zadaniach z wariantami zamiast pola będzie
  lista wariantów;
- **podpowiedzi** — pojawiają się same, według timera, którego odliczanie zaczyna się w chwili
  wejścia drużyny na zadanie. Do następnej podpowiedzi trwa odliczanie;
- **licznik kodów**, jeśli na zadaniu jest ich kilka i potrzebne są wszystkie;
- **zdjęcia**, jeśli autor je załączył — pasek miniatur pod treścią zadania i pod każdą
  podpowiedzią, która się pojawiła.

Panel odpowiedzi — pole do wpisania kodu, odliczanie do następnej podpowiedzi i naliczona kara,
jeśli jakaś jest — jest przypięty na dole ekranu i zostaje na miejscu, niezależnie od tego, do
której części strony przewiniesz. Wszystko inne przewija się jak zwykła strona: treść zadania,
zdjęcia, każda podpowiedź, która się pojawiła, i warianty odpowiedzi znajdują się powyżej panelu,
a długie zadanie trzeba przewijać.

Kliknięcie zdjęcia otwiera je w pełnym rozmiarze. Zamiast miniatury pliki PDF i animowane GIF-y
pokazują spinacz i nazwę pliku; otwierają się tak samo.

Kod jest przyjmowany niezależnie od wielkości liter i dodatkowych spacji na początku i końcu.
Jeden kod może mieć kilka poprawnych zapisów — autor ustala je sam.

**Ile kodów jest potrzebnych na zadaniu — decyduje autor.** Zadanie z kilkoma kodami ma dwa tryby:
„wystarczy dowolny z kodów” i „trzeba znaleźć wszystkie kody”. W drugim przypadku pokazywany jest
licznik „Poprawnych kodów wpisano: N z M”. Domyślnie wystarczy dowolny.

Kody może wpisywać dowolny członek drużyny, nie tylko kapitan. Postęp jest wspólny.

### Zadania z wariantami

Zadanie może nie pytać o kod, tylko proponować wybór spośród wariantów — wtedy zamiast pola do
wpisania będzie lista, a w niektórych zadaniach poprawnych wariantów jest kilka.

**Za błędnie wybrany wariant może zostać naliczona kara** — autor ustala ją w minutach. Kara nie
odbiera czasu na zadaniu i nie przyspiesza podpowiedzi: dolicza się do Twojego czasu końcowego na
mecie. Nalicza się ona **za każdym razem**, także za powtórny wybór tego samego błędnego wariantu
— inaczej dałoby się przejrzeć wszystkie warianty w cenie jednego błędu.

Bieżąca kara jest widoczna na stronie zadania, gdy tylko się pojawi.

Za błędnie wpisany **kod** kary nie ma — występuje ona tylko w zadaniach z wariantami.

### Język zadań

Jeśli gra jest wielojęzyczna, na stronie zadania jest osobny przełącznik języka zadań. Nie jest on
związany z językiem interfejsu: interfejs może być rosyjski, a zadania — angielskie.

Jeśli konkretne zadanie nie zostało jeszcze przetłumaczone na wybrany język, pokazywany jest
oryginał z odpowiednią adnotacją. Teksty nigdy nie są zastępowane tłumaczeniem maszynowym.

### Pauza

Organizator może wstrzymać grę — na przykład z powodu burzy albo zamkniętej ulicy. Wtedy nad
zadaniem pojawia się komunikat o pauzie.

Podczas pauzy:

- **odliczanie podpowiedzi jest zatrzymane.** Nowe podpowiedzi się nie pojawią, a czas pauzy nie
  „zje” Twojego zapasu — po wznowieniu gry odliczanie ruszy dokładnie od miejsca, w którym się
  zatrzymało;
- **kody nie są przyjmowane**, pole do wpisywania jest całkiem usunięte;
- zadanie pozostaje widoczne — można dalej nad nim myśleć.

Zostań na miejscu i czekaj na wznowienie gry.

### Rezygnacja z gry

Kapitan może wycofać drużynę z gry — „Zrezygnuj z gry”.

**To działanie jest jednostronne: drużyna sama nie może wrócić do gry.** Przywrócić ją może tylko
organizator gry albo administrator serwera — poproś ich, jeśli nacisnąłeś ten przycisk przez
pomyłkę.

### Wyniki

Po mecie drużyna widzi tabelę biegu: miejsce, drużyna, czas na mecie, kara i suma.

**Miejsce liczone jest według sumy, a nie według czasu na mecie.** Drużyna, która zebrała kary na
zadaniach z wariantami, znajdzie się niżej niż ta, która szła dłużej, ale bez błędów.

Pełny dziennik odpowiedzi z całej gry jest dostępny drużynom, które **ukończyły** grę (a nie
zrezygnowały z niej), oraz autorowi gry. Jeśli biegów było kilka, u góry jest przełącznik biegów.

---

## Dla autorów gry

### Tworzenie gry

„Utwórz grę >> ” w panelu gracza. Potrzebne będą nazwa, opis, data rozpoczęcia, ostateczny termin
zgłoszeń i maksymalna liczba drużyn.

Zaznaczenie **„Szkic?”** jest kluczowe:

- **szkic** jest widoczny tylko dla Ciebie. W nim można spokojnie wszystko przygotować;
- **odznaczysz — gra jest opublikowana**, widoczna dla wszystkich i dostępna do zgłoszeń.

Opublikowanej gry nie można edytować po jej rozpoczęciu.

Data rozpoczęcia, termin zgłoszeń i limit drużyn odnoszą się do bieżącego **biegu** gry. Dopóki
bieg jest jeden — a w większości gier tak właśnie jest — różnicy nie widać: formularz jest taki
sam.

### Zadania, kody i podpowiedzi

Zadania dodaje się ze strony gry („Dodaj nowe zadanie”). Kolejność zadań zmienia się strzałkami.

Zadanie ma:

- **nazwę i treść** — to, co zobaczy gracz;
- **kody** — poprawne odpowiedzi. Dla każdego kodu można ustawić kilka wariantów zapisu — są one
  traktowane jako równoważne;
- **sposób zaliczania kodów** — jeśli kodów jest kilka: „wystarczy dowolny z kodów” (domyślnie)
  albo „trzeba znaleźć wszystkie kody”;
- **warianty odpowiedzi** — jeśli zamiast wpisywania kodu gracz ma wybrać z listy (patrz niżej);
- **karę za błędną odpowiedź** w minutach — działa tylko w zadaniach z wariantami;
- **podpowiedzi** — każda z opóźnieniem w minutach od chwili wejścia drużyny na zadanie.

Podpowiedzi to główne narzędzie do zarządzania tempem. Drużyna, która utknęła na zadaniu, dostaje
je jedna po drugiej; ta, która wysunęła się do przodu, nie dostaje żadnej.

### Warianty odpowiedzi

Na stronie zadania jest „Warianty odpowiedzi”. Jeśli dla kodu ustawiono warianty, gracz nie
wpisuje tekstu, tylko wybiera z listy. Poprawnych wariantów może być kilka — wtedy zaliczane jest
tylko dokładne dopasowanie wybranego zestawu: „częściowo poprawnie” tu nie występuje, bo wynik w
grze mierzony jest czasem.

Kara za błędny wybór ustawiana jest na samym zadaniu, w minutach, i dolicza się do końcowego czasu
drużyny.

### Pliki i zdjęcia

Do zadania i do podpowiedzi można załączyć zdjęcia — tabliczkę z kodem, budynek, który trzeba
znaleźć, fragment mapy.

**Przesyła się raz, załącza dowolną liczbę razy.** Pliki należą do gry, a nie do zadania. „Pliki”
na stronie gry to biblioteka gry: prześlij tam plik, a potem załączaj go z formularza dowolnego
zadania albo podpowiedzi, wybierając z „Biblioteki gry”. To samo zdjęcie można podpiąć do kilku
zadań — nie jest przesyłane ponownie i nie zajmuje limitu dwa razy.

**Co można przesyłać.** Domyślnie JPEG, PNG, GIF, HEIC i PDF. Wartości domyślne to **25 MB na
plik**, **10 plików na jedno przesłanie** i **100 MB na grę**; wszystkie trzy administrator może
zmienić w ustawieniach, więc są to bieżące wartości, a nie niezmienne zasady. Na stronie plików
gry widać, ile jest wykorzystane: „Wykorzystano X MB z Y MB”. Obrazy mają dodatkowo pułap
50 megapikseli — nie dobija do niego żaden aparat w telefonie.

**HEIC jest konwertowany automatycznie.** Zdjęcia z iPhone'a przychodzą w formacie HEIC: są
przekodowywane przy przesyłaniu, a nie odrzucane.

**Typ pliku jest rozpoznawany po zawartości**, a nie po nazwie. Zmiana nazwy `coś.exe` na
`coś.jpg` i przesłanie się nie uda.

**Ze zdjęć usuwane są dane o wykonaniu.** JPEG, PNG i HEIC są dekodowane i zapisywane od nowa,
tracąc wszystkie metadane, w tym EXIF i GPS. Tutaj ma to większe znaczenie niż w zwykłej aplikacji:
w zadaniu „znajdź ten budynek” współrzędne wewnątrz zdjęcia to właśnie odpowiedź. Wyjątek: pliki
GIF i PDF są sprawdzane, ale nie przekodowywane, a ich metadane zostają zachowane. Nie używaj
pliku PDF, którego metadanych nie sprawdziłeś.

**Pliki są przypisywane do języków.** W grze wielojęzycznej każda karta językowa ma własny zestaw,
a na karcie głównej leży zestaw niezależny od języka. Gracz widzi pliki z karty głównej **plus**
pliki swojego języka — najpierw wspólne. Czyli zdjęcie, którego nie trzeba tłumaczyć, umieszcza
się na karcie głównej, i zobaczą je wszyscy; a szyld sfotografowany w dwóch językach — na dwóch
kartach językowych.

**Co widzi gracz:** pasek kwadratowych miniatur pod treścią zadania i taki sam pod każdą
podpowiedzią, która się pojawiła — ale nie wewnątrz samej treści. Kliknięcie otwiera plik w pełnym
rozmiarze. Zamiast miniatury pliki PDF i animowane GIF-y pokazują spinacz i nazwę pliku.

**Usuwanie.** Pliki usuwa się na stronie plików gry, i tam samo jest oznaczone, które z nich są
„nieużywane”. Dopóki gra trwa, usunięcie prosi najpierw o wpisanie nazwy pliku — to celowe
utrudnienie: plik usunięty w środku biegu znika drużynom, które akurat stoją z nim na ulicy.

Jeśli dane pliku znikną, błąd zwróci tylko ten obrazek — zadanie i jego treść nadal będą się
otwierać.

### Import zadań z listy

„Import poziomów z listy” na stronie gry — sposób, żeby nie zakładać dwudziestu zadań ręcznie.
Tekst wkleja się w całości: wiersz (albo kilka pod rząd) to treść zadania, dalej odpowiedzi.

```
Dojdź do rogu Kijowskiej i Czuj.
Na ścianie domu jest tabliczka z rokiem budowy.
A) 1967

Które miasto jest stolicą Białorusi?
A) Brześć
B) Grodno
C) *Mińsk
```

- jedna odpowiedź w postaci `A) KOD` — zwykłe zadanie z kodem;
- dwie i więcej — zadanie z wariantami; poprawny oznacza się gwiazdką, dwiema gwiazdkami — gdy
  poprawnych jest kilka;
- **wiersz w postaci „litera) tekst” zawsze jest czytany jako odpowiedź**, nawet w środku zadania.
  Treść zadania nie może zaczynać się w ten sposób.

Przed dodaniem pokazywany jest podgląd: co zostanie dodane, a co pominięte jako już istniejące.
Nie można importować do gry, która już się zaczęła.

### Gry wielojęzyczne

Gra ma język główny i listę języków, w których jest dostępna. Podczas edycji pojawiają się karty
językowe — jedna karta na każdy zadeklarowany język. Warianty odpowiedzi tłumaczy się osobno, w
formie listy, na stronie wariantów.

Kody odpowiedzi są wspólne dla wszystkich języków. Jeśli odpowiedź zapisuje się różnie, dodaj
każdy zapis jako osobny wariant kodu.

Załączone pliki też są przypisane do języków, przy czym się sumują, a nie zastępują nawzajem —
patrz [Pliki i zdjęcia](#pliki-i-zdjęcia).

Dwie zasady:

1. **Nie można opublikować gry z niepełnym tłumaczeniem.** Jeśli zadeklarowano rosyjski i
   angielski, a jakieś pole nie zostało przetłumaczone, publikacja zostanie odrzucona i pokazana
   zostanie lista brakujących pól.
2. **Języka głównego nie można zmienić po tym, jak pojawiły się tłumaczenia** — inaczej kolumny z
   tekstem zostałyby w jednym języku, a gra deklarowałaby inny.

### Zgłoszenia drużyn

Zgłoszenia widoczne są na stronie gry. Każde można przyjąć albo odrzucić. Liczba przyjętych
drużyn jest ograniczona maksimum, które ustawiłeś dla bieżącego biegu.

### Testowanie

**„Rozpocznij testowanie”** przełącza grę w tryb testowy: startuje ona natychmiast, i możesz
przejść ją samodzielnie — w trybie testowym autorowi wolno grać we własną grę.

**„Zakończ testowanie”** zwraca grę do szkicu i przywraca pierwotną datę rozpoczęcia.

> **Uwaga:** zakończenie testowania **usuwa wszystkie przejścia i dzienniki** tej gry. Na tym
> właśnie polega jego sens — usunąć ślady testu przed prawdziwą grą. Nie naciskaj tego przycisku
> w grze, w którą już grano naprawdę.

Jeśli testowanie się nie uruchamia, pokazana zostanie przyczyna — najczęściej jest to niepełne
tłumaczenie.

### Obserwacja gry

Ze strony listy gier, przy swojej grze:

| Link | Co pokazuje |
|---|---|
| (statystyki) | Wszystkie drużyny: na jakim zadaniu i ile czasu na nim spędzają |
| (transmisja na żywo) | Wszystkie wpisane kody z całej gry, w czasie rzeczywistym |
| (dziennik odpowiedzi) | Pełny dziennik wszystkich drużyn i zadań |

Strona statystyk to główny ekran podczas gry. Stamtąd też dostępna jest interwencja.

Wszystkie trzy ekrany są podpisane grą i biegiem, pokazują liczbę drużyn i zadań i mówią, w jakiej
strefie czasowej podano czas. Pełny dziennik jest podzielony na strony. Jeśli biegów było kilka,
u góry jest przełącznik „Biegi:” — poprzedni bieg nigdzie nie znika.

### Interwencja w trwającą grę

Na stronie statystyk swojej gry możesz:

**Wstrzymać grę / Wznowić grę.** Pauza zatrzymuje odliczanie podpowiedzi u wszystkich drużyn i
zabrania wpisywania kodów. Po zdjęciu pauzy każda drużyna dostaje dokładnie tyle czasu, ile jej
zostało. Korzystaj z tego przy burzy, sytuacji awaryjnej, zamkniętej ulicy.

**Przenieść drużynę na inne zadanie.** Dla drużyny, która utknęła na zadaniu, które się zepsuło:
kod nie pasuje, lokalizacja jest niedostępna. Odliczanie podpowiedzi na nowym zadaniu zaczyna się
od nowa, wpisane kody bieżącego zadania są resetowane.

**Przywrócić drużynę do gry.** Cofa „Zrezygnuj z gry”, jeśli kapitan nacisnął ten przycisk przez
pomyłkę. Odliczanie podpowiedzi zaczyna się od nowa.

**Zresetować odliczanie.** Zeruje czas na zadaniu — jeśli podpowiedzi zdążyły wyjść nie w porę.

**Zmienić regułę kodów na zadaniu** — „Wystarczy dowolny” / „Potrzebne wszystkie”. Ratuje, gdy
jeden z punktów w zadaniu z wieloma kodami okazał się niedostępny: zamiast rozwiązywać sprawę z
każdą drużyną osobno, łagodzisz samo zadanie dla wszystkich naraz.

Wszystko to jest dostępne, dopóki gra trwa, także podczas pauzy. Historia odpowiedzi (dzienniki)
nigdy nie zmienia się pod wpływem interwencji — pozostaje rzetelnym zapisem tego, co drużyna
naprawdę wpisywała.

### Zakończenie gry

**„ZAKOŃCZ GRĘ”** kończy grę dla wszystkich drużyn naraz.

**To nieodwracalne** — drużyny nie mogą już wpisywać kodów. Używaj, gdy gra rzeczywiście się
zakończyła.

Zakończoną grę można rozegrać ponownie: administrator serwera otwiera nowy bieg i zapisy zaczynają
się od nowa. Zadania, kody i podpowiedzi pozostają przy tym bez zmian, a wyniki poprzedniego biegu
są zachowywane osobno.

Grę zakończoną przez pomyłkę administrator może wznowić.

### Przekazanie autorstwa

Na stronie gry jest „Przekazanie autorstwa” — wpisz pseudonim nowego autora. Po tym gra w całości
staje się jego: on ją edytuje, przyjmuje zgłoszenia i interweniuje w jej przebieg.

Nie można przekazać autorstwa, dopóki gra trwa i dopóki edycja jest zablokowana przez
administratora.

### Usuwanie gry

Grę można usunąć **tylko wtedy, gdy jeszcze nikt w nią nie grał**. Gdy tylko pojawi się choć jedno
przejście, usunięcie jest zablokowane: zostawiłoby ono wiszące donikąd dzienniki i wyniki drużyn.

Dla gry, w którą już grano, jest wycofanie z publikacji — poproś o to administratora.

---

## Dla administratorów

Administrator serwera (superadmin) odpowiada za wszystkie gry, a nie tylko za swoje.

Uprawnienia nadaje inny administrator. Najpierwszy administrator jest wyznaczany z konsoli
serwera — inaczej nie miałby kto ich nadać (zobacz [instrukcję instalacji](deployment.ru.md#6-первый-администратор)).

### Co gdzie

Po otrzymaniu uprawnień w lewym menu pojawia się sekcja **„Administracja”**:

| Pozycja | Adres | Co tam jest |
|---|---|---|
| Przegląd | `/admin` | Podsumowanie: gry według statusu, łącznie graczy/drużyn/gier, zgłoszenia |
| Wszystkie gry | `/admin/games` | Wszystkie gry serwera z działaniami na nich |
| Gracze | `/admin/users` | Wszyscy zarejestrowani |
| Dziennik działań | `/admin/audit` | Kto co zrobił |

Ze strony przeglądu są jeszcze dwie: **„Wszystkie drużyny”** (`/admin/teams`) i **„Ustawienia
limitów”** (`/admin/settings`).

### Uprawnienia innych graczy

Na stronie gracza (`/admin/users/NUMER`) — przyciski „Nadaj uprawnienia administratora” i „Odbierz
uprawnienia administratora”.

Dwa ograniczenia, których nie da się znieść:

- **nie można odebrać uprawnień samemu sobie** — to zabezpieczenie przed przypadkową blokadą i
  gwarancja, że każde obniżenie uprawnień ma w dzienniku drugiego uczestnika;
- **nie można odebrać uprawnień ostatniemu administratorowi** — serwer nigdy nie powinien zostać
  bez administratora. Ta zasada obowiązuje także w konsoli.

Na stronie gracza widoczne są jego kontakty — telefon, Instagram, Telegram, komunikatory, data
urodzenia. Na liście ogólnej celowo ich nie ma: żeby zobaczyć kontakty, trzeba świadomie wejść na
stronę konkretnej osoby.

### Działania wobec graczy

Tam samo, na stronie gracza:

**Przenieść do drużyny.** Gdy dana osoba nie może odejść sama — na przykład kapitan zniknął, a
drużyna się rozpadła.

**Usunąć konto.** Na zawsze. Nie można usunąć samego siebie, ostatniego administratora, kapitana
(najpierw wyznacz drużynie innego) ani **autora gier** — inaczej zniknęłyby gry, w które grały
inne osoby.

**Zanonimizować konto.** To, co robi się zamiast usunięcia w przypadku autora gier: osoba znika z
list i z oczu, a jej gry pozostają na miejscu.

Nie można przenieść gracza, dopóki na trasie jest jego drużyna — albo ta, do której jest
przenoszony.

### Działania wobec drużyn

Na `/admin/teams`: **wyznaczyć kapitana** (gdy poprzedni zniknął i nie ma komu przekazać
kapitaństwa) oraz **usunąć drużynę** — tylko pustą i taką, która ani razu nie grała.

### Działania wobec gier

Na `/admin/games`:

**Wycofać z publikacji / Opublikować.** Usuwa grę z ogólnych list i zamyka dostęp dla postronnych.
Autor i administrator nadal ją widzą.

> Drużyny, które **już grają**, kontynuują grę — wycofanie z publikacji nie zrzuca ludzi z trasy w
> środku miasta. To celowe zachowanie.

**„Zablokuj” / „Odblokuj”.** Autor nie będzie mógł edytować gry, uruchamiać i kończyć testowania,
usuwać jej, kończyć jej ani przekazywać autorstwa. Korzystaj z tego, gdy trzeba wyjaśnić sytuację i
zabezpieczyć stan.

Zablokowanie nie przeszkadza autorowi **oglądać** swojej gry i dzienników — tylko je zmieniać.
Administratora nie ogranicza.

**Wznowić.** Cofa zakończenie gry, jeśli autor nacisnął „ZAKOŃCZ GRĘ” zbyt wcześnie.

**Zmienić autora.** To samo, co przekazanie autorstwa, ale bez pytania obecnego autora — na
wypadek, gdy go nie ma albo nie chce. W odróżnieniu od przekazania autorstwa działa zarówno w
zablokowanej grze, jak i w trwającej.

**Otworzyć nowy bieg.** Rozegrać tę samą grę jeszcze raz — patrz niżej.

**Zgłoszenia (N).** Konsola przyjmowania drużyn — patrz niżej.

**Usunąć.** Działa według tej samej zasady, co u autora: tylko jeśli w grę jeszcze nie grano. Dla
pozostałych — wycofanie z publikacji.

### Nowy bieg

„Otwórz nowy bieg” na `/admin/games` — formularz z datą rozpoczęcia, terminem zgłoszeń i limitem
drużyn. Dalej gra znowu przyjmuje zgłoszenia, a poprzednie wyniki zostają na miejscu, pod swoim
numerem biegu.

Dwa warunki:

- **poprzedni bieg musi być zakończony.** Nie można otworzyć nowego na miejscu trwającego;
- **w grze musi być co najmniej jedno zadanie.**

Data rozpoczęcia musi być w przyszłości, a termin zgłoszeń — wcześniejszy niż rozpoczęcie.

### Zgłoszenia do gry

„Zgłoszenia (N)” przy grze na `/admin/games` — ekran, na którym widać, kto zgłasza się do
bieżącego biegu, i można przyjąć albo odrzucić, nie będąc autorem.

Jest to potrzebne, gdy autor jest niedostępny, a gra lada chwila się zacznie: wcześniej
administrator musiałby przejmować całe autorstwo.

Ekran pokazuje zgłoszenia tylko bieżącego biegu i jest podpisany jego numerem.

### Ustawienia limitów

`/admin/settings` — ile rejestracji i ile próśb o reset hasła można zrobić z jednego adresu IP w
danym okresie. `0` wyłącza ograniczenie.

Wartości domyślne są dobrane dla zwykłego serwera. Podnosić je trzeba rzadko; obniżać — gdy ktoś
się dobija. Pamiętaj, że za jednym adresem może siedzieć cały klub albo cały akademik.

### Magazyn

Na `/admin` jest blok **„Magazyn”**: ile megabajtów przesłanych plików jest zajęte na serwerze i
jaki jest łączny limit.

Same ograniczenia są na `/admin/settings` i wszystkie to wartości domyślne, które można zmieniać:

| Ustawienie | Domyślnie | Co robi |
|---|---|---|
| Maksymalny rozmiar pliku (MB) | 25 | Na jeden plik, przy przesyłaniu |
| Plików na jedno przesłanie | 10 | Ile sztuk naraz |
| Limit na grę (MB) | 100 | Na grę, licząc oryginały i utworzone podglądy |
| Łączny limit serwera (MB) | 4096 | Na wszystkie gry razem |
| Nienaruszalny zapas miejsca na dysku (MB) | 3072 | Poniżej tego przesyłanie nie jest przyjmowane |
| Dozwolone rozszerzenia plików | `jpg jpeg png gif heic pdf` | Listę można tylko zawężać |

Warto wyjaśnić dwa z nich.

**Nienaruszalny zapas to hamulec bezpieczeństwa, a nie księgowość.** Zabrania przesyłania, gdy na
*dysku* jest mało miejsca, niezależnie od tego, ile komu zostało z limitu. Na jednym niewielkim
serwerze alternatywą byłoby zapchanie dysku i uronienie razem z przesyłaniem bazy danych oraz
kolejnego wdrożenia.

**Listę rozszerzeń można tylko zawęzić.** Przed użyciem jest ona zestawiana z wewnętrzną,
niezmienną listą: usunięcie `pdf` się uda, a dodanie `svg` — nie. Zrobiono to celowo: usunięte
formaty to właśnie te, które potrafią nosić w sobie kod wykonywalny.

Zwolnienie miejsca, którego pliki już nie zajmują, odbywa się nie przez przycisk, tylko na
serwerze — patrz [Zwolnienie miejsca na pliki](deployment.ru.md#9-освобождение-места-под-файлы)
w instrukcji instalacji.

### Interwencja w cudzych grach

Wszystko z rozdziału [Interwencja w trwającą grę](#interwencja-w-trwającą-grę) jest dostępne
administratorowi w **każdej** grze, a nie tylko we własnej: pauza, przeniesienie drużyny, powrót
do gry, reset odliczania, złagodzenie reguły kodów.

Właśnie do tego są potrzebne uprawnienia: autor gry może być niedostępny, a drużyna stoi w środku
miasta.

### Dziennik działań

`/admin/audit` — kto, co, kiedy i na czym.

**Co trafia do dziennika:** działania administratora w **cudzej** grze, działania wobec graczy i
drużyn, otwarcie biegu, zmiana autora, zmiana ustawień, nadawanie i odbieranie uprawnień.

**Co nie trafia:**

- działania autora we **własnej** grze. To zwykła praca, a nie administrowanie; inaczej dziennik
  utonąłby w rutynie;
- wyświetlenia. Dziennik odpowiada na pytanie „kto to zmienił”, a nie „kto to oglądał” — w tym nie
  rejestruje przeglądania kontaktów gracza;
- wyznaczenie samego pierwszego administratora z konsoli. Nie da się tego obejść: dziennik
  prowadzi aplikacja webowa, a konsola działa z jej pominięciem.

Wpisów w dzienniku **nie da się edytować ani usuwać** — ani z poziomu interfejsu, ani w żaden inny
sposób. Dziennik, który może redagować ten, o kim jest prowadzony, dziennikiem nie jest.

Nazwa gry albo pseudonim gracza zapisywane są w dzienniku **na moment działania**. Dlatego wpis o
usuniętej grze nadal nazywa ją po imieniu, a nie pokazuje numeru, który już donikąd nie prowadzi.

---

## Jeśli coś poszło nie tak

| Objaw | Co to znaczy |
|---|---|
| „Gra została wstrzymana przez organizatora” | Pauza. Czekaj, podpowiedzi nie idą, czas nie jest tracony |
| Nie wpuszcza na stronę gry przed startem | Gra jeszcze się nie zaczęła — to normalne |
| Przyszło hasło e-mailem, a e-maila nie ma | Sprawdź spam. Hasło można otrzymać ponownie przez „Nie pamiętasz hasła?” |
| „Zbyt wiele prób” przy rejestracji | Ograniczenie po adresie IP. Poczekaj albo poproś administratora o podniesienie limitu |
| Nie da się zmienić hasła w profilu | Potrzebne jest jeszcze bieżące hasło — to zabezpieczenie przed zmianą hasła z cudzej przeglądarki |
| Drużyna zrezygnowała z gry przez pomyłkę | Autor gry albo administrator może ją przywrócić |
| Nie da się opuścić drużyny ani przekazać kapitaństwa | Drużyna jest na trasie. Skład odblokowuje się po grze |
| Czas na stronie inny niż na zegarze | Sprawdź strefę czasową w profilu; ekrany dzienników są podpisane strefą |
| Nie uruchamia się testowanie | Najprawdopodobniej niepełne tłumaczenie — przyczyna zostanie pokazana |
| Nie udaje się usunąć gry | Już w nią grano. Skorzystaj z wycofania z publikacji |
| Autor nie może edytować gry | Albo gra się już zaczęła, albo edycja została zablokowana przez administratora |
| Nie można otworzyć nowego biegu | Poprzedni nie został zakończony, albo w grze nie ma ani jednego zadania |
| Miejsce w tabeli niższe niż się spodziewano | Do czasu na mecie doliczona kara za błędne warianty |
