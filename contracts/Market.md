# Market для вторичной торговли инвестиционными долями

## Концепция

Маркет позволяет инвесторам продавать **целиком всю свою инвестицию** в проектах (из Fundraise) другим пользователям до полного погашения займа. Покупатель получает право на claim всех будущих выплат по данной инвестиции.

**Важно:** Инвестор может продать только всю инвестицию целиком (весь `investedAmount` по проекту), частичная продажа не поддерживается.

## Архитектура контракта

### Основные структуры данных

```solidity
struct Listing {
    uint256 listingId;           // ID листинга
    address seller;              // Продавец (оригинальный инвестор)
    uint256 projectId;           // ID проекта в Fundraise
    uint256 investedAmount;      // Размер инвестиции (всегда полный investedAmount продавца)
    uint256 price;               // Цена в USDT/токенах займа
    uint256 createdAt;           // Время создания
    ListingStatus status;        // Статус: Active, Sold, Cancelled
}

enum ListingStatus {
    Active,
    Cancelled,
    Sold
}

// Маппинг: seller => projectId => listingId (для быстрой проверки активного листинга)
// 0 означает отсутствие активного листинга
mapping(address => mapping(uint256 => uint256)) public activeListingIds;

// Маппинг листингов
mapping(uint256 => Listing) public listings;

// Счетчик листингов
uint256 public listingCount;
```

### Основные методы контракта

#### 1. Создание листинга (продавец)

```solidity
function createListing(
    uint256 _projectId,
    uint256 _price         // Цена за всю инвестицию
) external returns (uint256 listingId)
```

**Логика:**
- Проверить, что у seller есть `investedAmount > 0` в Fundraise для данного проекта
- Проверить, что нет активного листинга для этого seller + projectId (`activeListingIds[seller][projectId] == 0`)
- Проверить статус проекта (только `Funded`) - если `Repaid`, то заем уже полностью погашен и продавать нечего
- Получить полный `investedAmount` и `totalClaimed` из Fundraise
- Вычислить максимальный возможный возврат = `investedAmount + (investedAmount * investorInterestRate / BASIS_POINTS)`
- Вычислить остаток для покупателя = `максимальный возврат - totalClaimed`
- **Проверить, что `_price <= остаток для покупателя`** - цена не может превышать то, что получит покупатель
- Создать листинг с `investedAmount = полная инвестиция продавца`
- Установить `activeListingIds[seller][projectId] = listingId`

**UI элементы:**
- Форма с выбором проекта из списка инвестиций пользователя (только проекты со статусом `Funded` и `investedAmount > 0`)
- Отображение полной суммы инвестиции (автоматически подставляется из `investedAmount`)
- Индикатор "Уже выставлено на продажу" (если есть активный листинг)
- Калькулятор цены с процентами от номинала (80%, 90%, 95%, custom)

**Расчет и отображение доходности:**

1. **Если НЕ продавать** (остаться инвестором):
   - Полный ожидаемый доход = `investedAmount * investorInterestRate / BASIS_POINTS`
   - Уже получено = `totalClaimed`
   - Осталось получить = `полный доход - totalClaimed`
   - Чистая прибыль = `полный доход - investedAmount` (без учета уже полученного)

2. **Если ПРОДАТЬ** по выбранной цене:
   - Получит сразу = `price` (цена продажи)
   - Уже получено = `totalClaimed`
   - Чистая прибыль от продажи = `price - investedAmount + totalClaimed` (или `price - investedAmount`, если считать что totalClaimed уже в кармане)
   - Сравнение с "не продавать": показывает выгоду/потерю

3. **Расчет для покупателя:**
   - Максимальный полный возврат = `investedAmount + (investedAmount * investorInterestRate / BASIS_POINTS)`
   - Покупатель получит = `максимальный возврат - totalClaimed` (все будущие выплаты)
   - **Максимальная допустимая цена = `максимальный возврат - totalClaimed`** (проверка в контракте)
   - Доходность покупателя = `(покупатель получит - price) / price * 100%`
   - Если цена превышает максимальную, транзакция отклонится

#### 2. Покупка листинга

```solidity
function buyListing(
    uint256 _listingId
) external nonReentrant
```

**Логика:**
- Проверить статус листинга (Active)
- Проверить, что buyer != seller
- Проверить актуальность листинга: проверить текущий `investedAmount` seller в Fundraise (должен совпадать с `listing.investedAmount`)
- Перевести токены от buyer к seller (через `safeTransferFrom`)
- Вызвать `transferInvestment()` в Fundraise для переноса всей инвестиции с seller на buyer
- Обновить статус листинга на Sold
- Обнулить `activeListingIds[seller][projectId] = 0`

**UI элементы:**
- Карточка листинга с деталями проекта
- Информация о доходности (APR, expected returns)
- Текущий статус погашения проекта
- График будущих выплат (если есть schedule)
- Кнопка "Купить" с подтверждением approve токенов

#### 3. Отмена листинга

```solidity
function cancelListing(uint256 _listingId) external
```

**Логика:**
- Проверить, что msg.sender == seller
- Проверить статус (Active)
- Обновить статус на Cancelled
- Обнулить `activeListingIds[seller][projectId] = 0`

#### 4. Обновление цены

```solidity
function updateListingPrice(uint256 _listingId, uint256 _newPrice) external
```

**Логика:**
- Проверить, что msg.sender == seller
- Проверить статус (Active)
- Обновить цену

## Требуемые изменения в Fundraise.sol

### 1. Трансфер инвестиций между пользователями

```solidity
function transferInvestment(
    uint256 _projectId,
    address _from,
    address _to,
    uint256 _amount  // Всегда равен полному investedAmount _from
) external onlyMarket
```

**Логика:**
- Проверить, что у _from достаточно investedAmount (== _amount)
- Получить текущий InvestorInfo для _from
- Уменьшить investorInfo[_from][_projectId].investedAmount до 0
- Уменьшить investorInfo[_from][_projectId].totalClaimed до 0
- Увеличить investorInfo[_to][_projectId].investedAmount на _amount
- Установить investorInfo[_to][_projectId].totalClaimed = 0 (покупатель начинает с нуля)

**Важно:** 
- Нужен модификатор `onlyMarket` в Fundraise
- В ManagerRegistry добавить функцию `isMarket(address)`
- Покупатель получает чистую инвестицию без учета уже полученных выплат продавцом

### 2. Вспомогательные view-функции (опционально)

```solidity
// В Market.sol - проверка, можно ли создать листинг
function canCreateListing(uint256 _projectId, address _seller) 
    public view returns (bool)
{
    // Проверить investedAmount > 0 и нет активного листинга
}

// В Market.sol - получение активного листинга
function getActiveListing(address _seller, uint256 _projectId) 
    public view returns (Listing memory)
{
    uint256 listingId = activeListingIds[_seller][_projectId];
    if (listingId == 0) revert("No active listing");
    return listings[listingId];
}
```

## UI/UX Frontend

### Страница "Мои инвестиции"

**Добавить для каждой инвестиции:**
- Кнопка "Продать инвестицию" (только если нет активного листинга)
- Индикатор "Выставлено на продажу" с ценой (если есть активный листинг)
- Кнопка "Отменить продажу" (если есть активный листинг)
- Ожидаемая доходность vs маркет цена

### Страница "Маркет" (новая)

#### Фильтры:
- По проектам
- По APR (доходности)
- По дисконту (скидке от номинала)
- По статусу проекта
- Сортировка по цене, APR, времени до погашения

#### Карточка листинга:
```
┌─────────────────────────────────────┐
│ Проект: Project Name                │
│ Borrower: 0x123...                  │
│                                     │
│ Полная инвестиция: 1,000 USDT      │
│ Цена продажи: 950 USDT             │
│ Скидка: -5%                         │
│                                     │
│ Уже получено: 50 USDT (5%)         │
│ Доступно к claim: 100 USDT         │
│ Ожидаемый total: 1,100 USDT (10%)  │
│                                     │
│ Ваша доходность: ~15.8% APR        │
│                                     │
│ Статус проекта: Funded (30 days)   │
│                                     │
│ [Купить за 950 USDT]               │
└─────────────────────────────────────┘
```

### Модальное окно создания листинга

```
┌─────────────────────────────────────┐
│ Продажа инвестиции                  │
│                                     │
│ Проект: [Dropdown]                  │
│                                     │
│ Ваша инвестиция: 5,000 USDT        │
│ (продается целиком)                │
│                                     │
│ ─────────────────────────────────  │
│ ДОХОДНОСТЬ ПРОЕКТА                  │
│ ─────────────────────────────────  │
│ investorInterestRate: 10%           │
│ Ожидаемый total return: 5,500 USDT │
│ Уже получено (totalClaimed): 250 USDT │
│ Осталось получить: 250 USDT         │
│                                     │
│ Если НЕ продавать:                  │
│ • Получите еще: 250 USDT           │
│ • Чистая прибыль: 500 USDT (10%)   │
│                                     │
│ ─────────────────────────────────  │
│ ЦЕНА ПРОДАЖИ                        │
│ ─────────────────────────────────  │
│ Максимальная цена: 5,250 USDT      │
│ (остаток для покупателя)           │
│                                     │
│ ○ 95% номинала (4,750 USDT) ✓      │
│   → Ваша прибыль: -250 USDT (-5%)  │
│   → Потеряете 250 USDT vs не продавать │
│                                     │
│ ○ 90% номинала (4,500 USDT) ✓      │
│   → Ваша прибыль: -500 USDT (-10%) │
│   → Потеряете 500 USDT vs не продавать │
│                                     │
│ ⚠ 105% номинала (5,250 USDT)       │
│   → Превышает максимум!            │
│   → Транзакция будет отклонена     │
│                                     │
│ ● Custom: [____] USDT              │
│   (макс: 5,250 USDT)               │
│                                     │
│ ─────────────────────────────────  │
│ ДЛЯ ПОКУПАТЕЛЯ                      │
│ ─────────────────────────────────  │
│ Покупатель заплатит: 4,750 USDT    │
│ Покупатель получит: ~5,250 USDT    │
│ (все будущие выплаты)              │
│ Доходность для покупателя: ~10.5%  │
│                                     │
│ [Отмена]  [Создать листинг]        │
└─────────────────────────────────────┘
```

**Примечание:** Расчеты обновляются динамически при изменении цены продажи.

## Безопасность и ограничения

### Проверки в контракте:
1. **Двойная трата**: Проверка `activeListingIds` предотвращает создание нескольких листингов для одной инвестиции
2. **Целостность листинга**: При покупке проверяется, что `investedAmount` продавца не изменился с момента создания листинга
3. **Максимальная цена**: Цена не может превышать потенциальный возврат для покупателя (`price <= максимальный возврат - totalClaimed`). Это гарантирует, что покупатель не заплатит больше, чем сможет получить
4. **Claim блокировка**: При наличии активного листинга продавец не должен делать claim (это проверяется через UI, но можно добавить в claim функцию проверку)
5. **Статус проекта**: Продажа только для `Funded` проектов (в `Repaid` заем уже полностью погашен и продавать нечего)
6. **Валидация трансфера**: Проверка баланса перед transfer в Fundraise
7. **Reentrancy**: NonReentrant на buyListing

### Дополнительные фичи (опционально):

#### 1. Предложения (offers)
Покупатель может сделать offer ниже запрашиваемой цены, продавец может принять.

#### 3. Аукцион
Вместо fixed price использовать auction механику.

#### 4. Batch operations
Возможность купить несколько листингов одной транзакцией.

## События (Events)

```solidity
event ListingCreated(
    uint256 indexed listingId,
    address indexed seller,
    uint256 indexed projectId,
    uint256 investedAmount,  // Полная инвестиция
    uint256 price
);

event ListingBought(
    uint256 indexed listingId,
    address indexed buyer,
    address indexed seller,
    uint256 indexed projectId,
    uint256 investedAmount,  // Полная инвестиция
    uint256 price
);

event ListingCancelled(
    uint256 indexed listingId,
    address indexed seller,
    uint256 indexed projectId
);

event ListingPriceUpdated(
    uint256 indexed listingId,
    uint256 oldPrice,
    uint256 newPrice
);
```

## Комиссии платформы (опционально)

```solidity
uint256 public marketFeeRate; // 1% = 10000 (из BASIS_POINTS)
address public marketFeeTreasury;

// В buyListing забирать комиссию:
uint256 fee = (price * marketFeeRate) / BASIS_POINTS;
loanToken.safeTransfer(seller, price - fee);
loanToken.safeTransfer(marketFeeTreasury, fee);
```

## Интеграция с RewardSystem

При трансфере инвестиции нужно решить:
- Переносятся ли накопленные rewards на покупателя?
- Или rewards остаются у оригинального инвестора?

**Рекомендация**: Rewards остаются у оригинального инвестора, новый инвестор начинает накапливать rewards с момента покупки.

## Интеграция фронтенда (без бекенда)

Все взаимодействие происходит напрямую через смарт-контракты. Бекенд не требуется.

### Работа с данными

#### Получение списка активных листингов:
1. **Через события**: Читать `ListingCreated` events и фильтровать по `status == Active`
2. **Через view-функции**: Сканировать `listingCount` и вызывать `listings(id)` для каждого ID
3. **Фильтрация на фронте**: По projectId, цене, APR и т.д.

#### Получение листингов продавца:
1. Использовать событие `ListingCreated` с фильтром по `seller == address`
2. Или проверять `activeListingIds[seller][projectId]` для каждой инвестиции пользователя

#### Покупка:
- Прямой вызов `buyListing(listingId)` из фронтенда
- Перед покупкой вызвать `approve()` для токена займа на сумму `listing.price`

#### Создание листинга (sell):
- Прямой вызов `createListing(projectId, price)` из фронтенда
- Фронтенд автоматически получает `investedAmount` через вызов `investorInfo(seller, projectId)` в Fundraise

### View-функции для фронтенда

```solidity
// Получить листинг по ID
function getListing(uint256 _listingId) external view returns (Listing memory)

// Получить активный листинг продавца для проекта
function getActiveListing(address _seller, uint256 _projectId) 
    external view returns (Listing memory)

// Проверить, можно ли создать листинг
function canCreateListing(uint256 _projectId, address _seller) 
    external view returns (bool)

// Получить все активные листинги для проекта (требует итерации на фронте)
function getActiveListingsForProject(uint256 _projectId) 
    external view returns (uint256[] memory listingIds)
```

### События для отслеживания

Фронтенд подписывается на события для real-time обновлений:
- `ListingCreated` - новый листинг
- `ListingBought` - листинг куплен
- `ListingCancelled` - листинг отменен
- `ListingPriceUpdated` - цена изменена

### Аналитика на фронтенде

**На странице маркета показывать:**
- Общий объем торгов: суммировать `price` из всех `ListingBought` событий
- Средняя скидка: вычислять `(investedAmount - price) / investedAmount * 100`
- Самые ликвидные проекты: сортировать по количеству `ListingBought` events
- История цен: все `ListingBought` events с фильтром по `projectId`

**График цен:**
- Строить график на основе `ListingBought` событий (timestamp, price, investedAmount)
- Рассчитывать APR для покупателей на момент покупки

### Рекомендуемая структура фронтенда

```
MarketPage (Страница маркета)
├── FilterPanel (Фильтры: projectId, minAPR, maxPrice)
├── ListingList (Список активных листингов)
│   └── ListingCard
│       ├── ProjectInfo (из Fundraise)
│       ├── ListingDetails (price, investedAmount, discount)
│       ├── ExpectedReturns (калькулятор доходности)
│       └── BuyButton → buyListing(listingId)
│
MyInvestmentsPage
└── InvestmentCard
    ├── InvestmentInfo
    ├── "Продать" → CreateListingModal → createListing(projectId, price)
    └── ActiveListingInfo (если есть активный листинг)
        └── "Отменить" → cancelListing(listingId)

CreateListingModal
├── ProjectSelector (только проекты с investedAmount > 0)
├── PriceInput (с пресетами: 95%, 90%, 85%)
└── SubmitButton → createListing(projectId, price)
```

