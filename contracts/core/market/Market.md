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

// seller => projectId => positionIndex => saleId (0 = нет активной продажи по этой позиции)
mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public activePositionSaleIds;

// Слот занят и не читается: удалять нельзя, сдвинет layout живого прокси.
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

## Подписи бэкенда

Листинг и покупка требуют подписи доверенного ключа. Формат — EIP-712, домен
`EIP712Domain(uint256 chainId,address verifyingContract)`, то есть подпись привязана и к сети, и к
адресу этого контракта: перенести её на другую сеть или на соседний контракт нельзя.

```
Sell(address seller,uint256 projectId,uint256 price,uint256 positionIndex,uint256 deadline)
SellFor(address recovery,address owner,uint256 projectId,uint256 price,uint256 positionIndex,uint256 deadline)
Buy(address buyer,uint256 saleId)
```

`seller` и `recovery` — это `msg.sender`, то есть подпись выдаётся конкретному отправителю.

**Нонса нет нигде, и для листинга он не нужен.** Выставление опустошает ту позицию, которую называет
подпись: `transferPosition` переносит её в marketCell и обнуляет исходный индекс. Повторный вызов с
той же подписью упирается в `PositionHasZeroAmount`. Отмена возвращает позицию **под новым индексом**
— массив позиций в `Fundraise` только растёт, удаление делается обнулением на месте, а не
swap-and-pop, — поэтому старая подпись продолжает указывать на вечно пустой слот. У `Sell` и `SellFor`
есть ещё и `deadline`.

**`Buy` одноразов по состоянию лота:** после покупки `status` уходит из `Active`, и повторный
вызов не проходит проверку.

## Методы контракта

### sell(uint256 _projectId, uint256 _price, uint256 _positionIndex, uint256 _deadline, bytes _sig) → saleId

**Проверки:**

- У продавца есть инвестиция: `investorInfo[seller][projectId].investedAmount > 0`
- Нет активной продажи по этой позиции: `activePositionSaleIds[seller][projectId][positionIndex] == 0`
- Подпись бэкенда действительна и не просрочена: `block.timestamp <= _deadline`
- Проект в стадии **Funded**
- `maxReturn >= totalClaimed`, `price <= (maxReturn - totalClaimed)`

**Действия:** входов три — `sell` без получателя выручки, `sell` с `_proceedsTo` и `sellFor` для позиции скомпрометированного адреса, вызываемый с адреса восстановления; без него получателем записывается сам продавец. Получателем принимается только сам продавец или его эскроу мандата, принадлежность выводится из адреса через `factory.isEscrowOf`. Создаётся marketCell, вызывается `Fundraise.transferPosition(projectId, seller, marketCell, positionIndex, saleId)`, создаётся запись Sale (status = Active), выставляется `activePositionSaleIds[seller][projectId][positionIndex] = saleId`. Событие: `SaleCreated`.

### buy(uint256 _saleId, bytes _sig)

**Проверки:** sale существует, status == Active, msg.sender != seller, у marketCell есть инвестиция в Fundraise.

**Действия:** покупатель переводит loan token: `feeAmount` на контракт (accumulatedFees), `sellerAmount = price - feeAmount` — получателю. Получатель разрешается в момент покупки: адрес восстановления, если продавец помечен скомпрометированным, иначе `proceedsTo` лота, иначе сам продавец. Событие: `SaleProceedsPaid`. Вызов `Fundraise.transferPosition(projectId, marketCell, buyer, 0, saleId)` — у ячейки позиция всегда нулевая. Sale.status = Sold, activeSaleIds обнуляется, saleId добавляется в boughtSales[buyer] и soldSales[seller]. Событие: `SaleBought`, при feeAmount > 0 — `FeeCollected`.

### cancel(uint256 _saleId)

**Проверки:** `msg.sender` — продавец либо его адрес восстановления (`recipientOf(seller)`),
status == Active. Адрес восстановления здесь не удобство: лот скомпрометированного продавца
выставлен быть не может, а позиция лежит на служебной ячейке, и вернуть её иначе некому. Отмена
доступна в любой стадии проекта: продавец забирает собственную позицию обратно.

**Действия:** `Fundraise.transferPosition(projectId, marketCell, seller, 0, saleId)` — позиция возвращается продавцу. Sale.status = Cancelled, activeSaleIds обнуляется. Событие: `SaleCancelled`.

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

Fundraise предоставляет `transferPosition(projectId, from, to, positionIndex, id)`, вызываемый только с адреса, зарегистрированного в ManagerRegistry как Market (`isMarket(msg.sender)`). Переносится **одна позиция** по индексу, а не весь агрегат: доля отметки `totalClaimed` выводится из агрегата пропорционально размеру позиции с округлением вверх, чтобы покупатель не смог заклеймить уже выплаченное.

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
