# Market — технический референс (вторичная торговля инвестициями)

## Концепция

Контракт Market позволяет инвесторам продавать **целиком всю свою инвестицию** в проектах (из Fundraise) другим пользователям до полного погашения займа. Покупатель получает право на claim всех будущих выплат по данной инвестиции. Реализация использует **Sale** и временный адрес **marketCell**; частичная продажа не поддерживается.

## Архитектура контракта

### Структуры данных

```solidity
enum SaleStatus {
    Active,
    Sold,
    Cancelled
}

struct Sale {
    uint256 saleId;
    address seller;
    address buyer;
    uint256 projectId;
    address marketCell;    // Детерминированный адрес-контейнер для позиции
    uint256 price;
    uint256 fee;           // platformFee в basis points на момент создания
    uint256 maxReturn;     // investedAmount + (investedAmount * investorInterestRate / BASIS_POINTS)
    uint256 totalClaimed;  // Уже получено продавцом на момент создания
    uint256 createdAt;
    SaleStatus status;
}

// seller => projectId => saleId (0 = нет активной продажи)
mapping(address => mapping(uint256 => uint256)) public activeSaleIds;

mapping(uint256 => Sale) public sales;
uint256 public saleCount;

mapping(address => uint256[]) public soldSales;   // История проданных
mapping(address => uint256[]) public boughtSales;  // История купленных

uint256 public constant BASIS_POINTS = 1000000;   // 1% = 10000
uint256 public platformFee;
mapping(address => uint256) public accumulatedFees;
```

### marketCell

При вызове `sell(projectId, price)` контракт создаёт детерминированный адрес **marketCell**, в который переводится вся позиция продавца в Fundraise:

- `hash = keccak256(abi.encodePacked(saleId, seller, projectId, address(this), block.chainid))`
- `marketCell = address(uint160((uint256(saleId) << 128) | (uint256(hash) & 0xFFFFFFFFFFFFFFFFFFFFFFFF)))`

Позиция хранится в marketCell до `buy(saleId)` (перевод покупателю) или `cancel(saleId)` (возврат продавцу). Обновление цены после создания продажи не предусмотрено — нужно отменить и создать новую.

## Методы контракта

### sell(uint256 _projectId, uint256 _price) → saleId

**Проверки:**

- У продавца есть инвестиция: `investorInfo[seller][projectId].investedAmount > 0`
- Нет активной продажи: `activeSaleIds[seller][projectId] == 0`
- Проект в стадии **Funded**
- `maxReturn >= totalClaimed`, `price <= (maxReturn - totalClaimed)`

**Действия:** создаётся marketCell, вызывается `Fundraise.transferInvestment(projectId, seller, marketCell, true, saleId)`, создаётся запись Sale (status = Active), выставляется `activeSaleIds[seller][projectId] = saleId`. Событие: `SaleCreated`.

### buy(uint256 _saleId)

**Проверки:** sale существует, status == Active, msg.sender != seller, у marketCell есть инвестиция в Fundraise.

**Действия:** покупатель переводит loan token: `feeAmount` на контракт (accumulatedFees), `sellerAmount = price - feeAmount` — продавцу. Вызов `Fundraise.transferInvestment(projectId, marketCell, buyer, false, saleId)`. Sale.status = Sold, activeSaleIds обнуляется, saleId добавляется в boughtSales[buyer] и soldSales[seller]. Событие: `SaleBought`, при feeAmount > 0 — `FeeCollected`.

### cancel(uint256 _saleId)

**Проверки:** msg.sender == seller, status == Active.

**Действия:** `Fundraise.transferInvestment(projectId, marketCell, seller, false, saleId)` — позиция возвращается продавцу. Sale.status = Cancelled, activeSaleIds обнуляется. Событие: `SaleCancelled`.

### Админ и view

- **setPlatformFee(uint256 _fee)** (onlyOwner): комиссия в basis points.
- **withdrawFees(address _token, address _to)** (onlyOwner): вывод накопленных комиссий.
- **getSale(uint256 _saleId)** → Sale
- **getSoldSales(address _user)** → uint256[] saleIds
- **getBoughtSales(address _user)** → uint256[] saleIds

## События

- `SaleCreated(saleId, seller, projectId, marketCell, price)`
- `SaleBought(saleId, buyer, seller, projectId)`
- `SaleCancelled(saleId, seller, projectId)`
- `PlatformFeeUpdated(oldFee, newFee)`
- `FeeCollected(token, amount)`

## Интеграция с Fundraise

Fundraise предоставляет `transferInvestment(projectId, from, to, onlyFundedStage, id)`, вызываемый только с адреса, зарегистрированного в ManagerRegistry как Market (`isMarket(msg.sender)`). При вызове вся позиция (investedAmount и totalClaimed) переносится с `from` на `to`.

## Безопасность

- Один активный Sale на пару (seller, projectId) благодаря activeSaleIds.
- Цена ограничена остатком для покупателя: `price <= maxReturn - totalClaimed`.
- При buy проверяется наличие инвестиции у marketCell в Fundraise.
- ReentrancyGuard на sell, buy, cancel.

## Интеграция фронтенда

- **Активные продажи:** итерация по saleCount и фильтр по sales[id].status == Active или события SaleCreated/SaleBought/SaleCancelled.
- **Продажи пользователя:** activeSaleIds[user][projectId] для проверки «уже выставлено»; getSoldSales(user), getBoughtSales(user) для истории.
- **Покупка:** approve(loanToken, price) затем buy(saleId); покупатель платит полную price (контракт сам раскладывает на fee и sellerAmount).
- Подробнее расчёты доходности и UI — в [docs/CLASSIFIEDS_AND_FUNDRAISE.md](../docs/CLASSIFIEDS_AND_FUNDRAISE.md) и в разделе UI/UX ниже (карточка Sale вместо Listing).

## UI/UX (карточка продажи)

Карточка на маркете может отображать: проект, заёмщика, полную инвестицию (из Fundraise по marketCell или из sale.maxReturn/totalClaimed), цену продажи, скидку к номиналу, ожидаемый возврат для покупателя, кнопку «Купить» → buy(saleId). Для «Мои инвестиции»: кнопка «Продать» → sell(projectId, price); при активной продаже — индикатор и «Отменить» → cancel(saleId).
