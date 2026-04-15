//+------------------------------------------------------------------+
//|                                                 robot_ma_rsi.mq5 |
//|                      Copyright 2026, Space-55, Happy-Philosopher |
//|                                       Professional version v2.12 |
//+------------------------------------------------------------------+
#property copyright "Space-55, Happy-Philosopher"
#property version   "2.12"
#property description "Советник с управлением рисками, ATR-стопами, трейлингом, фильтром ADX и защитой от просадки"

//+------------------------------------------------------------------+
//| Типы цен для MA (чтобы в настройках были понятные пункты)        |
//+------------------------------------------------------------------+
enum ENUM_MA_PRICE_TYPE
{
   MA_PRICE_CLOSE = 0,    // Close price
   MA_PRICE_OPEN = 1,     // Open price
   MA_PRICE_HIGH = 2,     // High price
   MA_PRICE_LOW = 3,      // Low price
   MA_PRICE_MEDIAN = 4,   // Median price (High+Low)/2
   MA_PRICE_TYPICAL = 5,  // Typical price (High+Low+Close)/3
   MA_PRICE_WEIGHTED = 6  // Weighted close (High+Low+Close+Close)/4
};

//+------------------------------------------------------------------+
//| Входные параметры (с настройками по умолчанию)                   |
//+------------------------------------------------------------------+
// --- Индикаторы ---
input group              "--- Индикаторы ---"
input int                FastMAPeriod = 5;                // Период быстрой MA
input int                SlowMAPeriod = 12;               // Период медленной MA
input ENUM_MA_PRICE_TYPE MAPriceType = MA_PRICE_CLOSE;    // Тип цены для MA
input int                MAType = MODE_EMA;               // Тип MA (1=EMA, 2=SMMA, 3=LWMA)

input int                RSIPeriod = 14;                  // Период RSI
input int                RSIUpperLevel = 70;              // Верхний уровень RSI (для продаж)
input int                RSILowerLevel = 30;              // Нижний уровень RSI (для покупок)

input int                ADXPeriod = 14;                  // Период ADX
input double             ADXThreshold = 25.0;             // Минимальное значение ADX для входа (тренд есть)

input int                ATRPeriod = 14;                  // Период ATR для расчёта SL/TP
input double             ATRMultiplierSL = 1.5;           // Множитель ATR для Stop Loss
input double             ATRMultiplierTP = 3.0;           // Множитель ATR для Take Profit

// --- Управление капиталом ---
input group    "--- Управление капиталом ---"
input double   RiskPercent = 1.0;               // Риск на сделку (% от баланса)
input double   LotFixed = 0.0;                  // Фиксированный лот (если >0, то RiskPercent игнорируется)

// --- Защита от просадок ---
input group    "--- Защита от просадок ---"
input double   MaxDailyLossPercent = 5.0;       // Максимальный убыток за день (% от баланса на начало дня)
input double   MaxTotalDrawdownPercent = 20.0;  // Глобальная максимальная просадка от пика баланса (0=отключено)
input int      MaxStopLossPoints = 500;         // Максимальный стоп-лосс в пунктах (защита от слишком широких стопов)

// --- Трейлинг-стоп ---
input group    "--- Трейлинг-стоп ---"
input bool     UseTrailingStop = true;          // Использовать трейлинг-стоп
input int      TrailingStartPoints = 30;        // Активация трейлинга при прибыли (пунктах)
input int      TrailingStepPoints = 10;         // Шаг трейлинга (пунктах)

// --- Фильтр времени торговли ---
input group    "--- Фильтр времени торговли ---"
input bool     UseTimeFilter = false;           // Ограничить время торговли
input int      StartHour = 8;                   // Начало торговли (час серверного времени)
input int      EndHour = 20;                    // Конец торговли (час)

// --- Общие настройки ---
input group    "--- Общие настройки ---"
input int      Slippage = 10;                   // Проскальзывание (пункты)
input ulong    MagicNumber = 64385;             // Magic Number
input bool     PrintLog = true;                 // Печать логов в эксперты

//+------------------------------------------------------------------+
//| Глобальные переменные                                             |
//+------------------------------------------------------------------+
// Хэндлы индикаторов
int fastMA_handle, slowMA_handle, rsi_handle, adx_handle, atr_handle;

// Буферы для значений индикаторов
double fastMA[];
double slowMA[];
double rsi[];
double adx[];
double atr[];

// Переменные для управления сигналами на баре
datetime lastBarTime = 0;
bool attemptOnCurrentBar = false;

// Переменные для дневной защиты
double dailyStartBalance = 0.0;
double dailyLossLimit = 0.0;
datetime lastDayCheck = 0;

// Переменные для глобальной защиты от просадки
double peakBalance = 0.0;

//+------------------------------------------------------------------+
//| Функция нормализации лота                                         |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   lot = MathRound(lot / stepLot) * stepLot;
   return lot;
}

//+------------------------------------------------------------------+
//| Расчёт лота на основе риска (в пунктах)                           |
//+------------------------------------------------------------------+
double GetLotByRisk(double riskPercent, int slPoints)
{
   if(slPoints <= 0) return 0.0;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * riskPercent / 100.0;
   
   // Стоимость одного пункта для 1 лота
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   // Для валютных пар обычно tickValue дано за tick размером point
   // Но бывают исключения (индексы). Используем универсальную формулу:
   // loss = slPoints * point * lot * tickValue? Нет, проще: стоимость пункта * пункты
   double lossPerLot = slPoints * tickValue;
   if(lossPerLot <= 0) return 0.0;
   
   double lot = riskMoney / lossPerLot;
   lot = NormalizeLot(lot);
   return lot;
}

//+------------------------------------------------------------------+
//| Проверка и возврат корректного уровня стопа (с мин/макс лимитами)|
//+------------------------------------------------------------------+
int GetValidStopLevel(int reqPoints)
{
   // Минимальное расстояние, разрешённое брокером
   long minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   
   int result = reqPoints;
   
   // Проверка на минимальный допустимый стоп
   if(result < (int)minDist)
   {
      if(PrintLog) Print("Стоп-лосс ", reqPoints, " меньше минимального ", minDist, ". Установлен ", minDist);
      result = (int)minDist;
   }
   
   // Проверка на максимальный стоп (защита от чрезмерного риска)
   if(result > MaxStopLossPoints)
   {
      if(PrintLog) Print("Стоп-лосс ", reqPoints, " превышает максимальный ", MaxStopLossPoints, ". Установлен ", MaxStopLossPoints);
      result = MaxStopLossPoints;
   }
   
   // Защита от нулевого или отрицательного значения
   if(result <= 0)
   {
      if(PrintLog) Print("Стоп-лосс ", reqPoints, " меньше или равен 0. Установлен минимальный ", minDist);
      result = (int)minDist;
   }
   
   return result;
}

//+------------------------------------------------------------------+
//| Нормализация цены                                                |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

//+------------------------------------------------------------------+
//| Проверка существования позиции по Magic                           |
//+------------------------------------------------------------------+
bool PositionExists()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Проверка лимита дневных убытков                                   |
//+------------------------------------------------------------------+
bool IsDailyLossExceeded()
{
   MqlDateTime today;
   TimeCurrent(today);
   datetime currentDay = StringToTime(StringFormat("%04d.%02d.%02d", today.year, today.mon, today.day));
   
   if(lastDayCheck != currentDay)
   {
      lastDayCheck = currentDay;
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyLossLimit = dailyStartBalance * MaxDailyLossPercent / 100.0;
      if(PrintLog) Print("Новый день. Баланс начала дня: ", dailyStartBalance, ", лимит убытка: ", dailyLossLimit);
   }
   
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyLoss = dailyStartBalance - currentEquity;
   if(dailyLoss > dailyLossLimit && MaxDailyLossPercent > 0)
   {
      if(PrintLog) Print("Превышен дневной лимит убытка. Торговля заблокирована до следующего дня.");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Проверка глобальной максимальной просадки                         |
//+------------------------------------------------------------------+
bool IsTotalDrawdownExceeded()
{
   if(MaxTotalDrawdownPercent <= 0) return false;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance > peakBalance) peakBalance = balance;
   double drawdownPercent = (peakBalance - balance) / peakBalance * 100.0;
   if(drawdownPercent >= MaxTotalDrawdownPercent)
   {
      if(PrintLog) Print("Превышена глобальная максимальная просадка: ", drawdownPercent, "%. Торговля остановлена.");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Проверка фильтра по времени                                       |
//+------------------------------------------------------------------+
bool IsTimeAllowed()
{
   if(!UseTimeFilter) return true;
   MqlDateTime tm;
   TimeCurrent(tm);
   int hour = tm.hour;
   if(hour >= StartHour && hour < EndHour) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Трейлинг-стоп для всех позиций                                    |
//+------------------------------------------------------------------+
void UpdateTrailingStops()
{
   if(!UseTrailingStop) return;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 
                            SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                            SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double profitPoints = 0;
      
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         profitPoints = (currentPrice - openPrice) / point;
         if(profitPoints >= TrailingStartPoints)
         {
            double newSL = NormalizePrice(currentPrice - TrailingStepPoints * point);
            if(newSL > currentSL)
            {
               MqlTradeRequest req = {};
               MqlTradeResult res = {};
               req.action = TRADE_ACTION_SLTP;
               req.symbol = _Symbol;
               req.position = ticket;
               req.sl = newSL;
               req.tp = currentTP;
               req.magic = MagicNumber;
               if(OrderSend(req, res))
                  if(PrintLog) Print("Трейлинг BUY: новый SL = ", newSL);
            }
         }
      }
      else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
      {
         profitPoints = (openPrice - currentPrice) / point;
         if(profitPoints >= TrailingStartPoints)
         {
            double newSL = NormalizePrice(currentPrice + TrailingStepPoints * point);
            if(newSL < currentSL || currentSL == 0)
            {
               MqlTradeRequest req = {};
               MqlTradeResult res = {};
               req.action = TRADE_ACTION_SLTP;
               req.symbol = _Symbol;
               req.position = ticket;
               req.sl = newSL;
               req.tp = currentTP;
               req.magic = MagicNumber;
               if(OrderSend(req, res))
                  if(PrintLog) Print("Трейлинг SELL: новый SL = ", newSL);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Открытие ордера (обобщённая функция)                              |
//+------------------------------------------------------------------+
bool OpenOrder(int direction, double lot, int slPoints, int tpPoints)
{
   if(!IsTimeAllowed())
   {
      if(PrintLog) Print("Вне разрешённого времени торговли.");
      return false;
   }
   if(IsDailyLossExceeded() || IsTotalDrawdownExceeded()) return false;
   
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;
   
   double price = (direction == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   price = NormalizePrice(price);
   
   // Получаем ATR для динамических стопов (если нужно)
   if(CopyBuffer(atr_handle, 0, 0, 1, atr) < 1)
   {
      if(PrintLog) Print("Ошибка копирования ATR, используем фиксированные стопы");
   }
   else
   {
      double atrValue = atr[0];
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int atrPoints = (int)MathRound(atrValue / point);
      slPoints = (int)MathMax(slPoints, (int)(atrPoints * ATRMultiplierSL));
      tpPoints = (int)MathMax(tpPoints, (int)(atrPoints * ATRMultiplierTP));
      if(PrintLog) Print("ATR = ", atrValue, " (", atrPoints, " пунктов), установлен SL=", slPoints, " TP=", tpPoints);
   }
   
   slPoints = GetValidStopLevel(slPoints);
   tpPoints = GetValidStopLevel(tpPoints);
   
   // 1. Открываем ордер без SL и TP
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = _Symbol;
   req.volume = lot;
   req.type = (ENUM_ORDER_TYPE)direction;
   req.price = price;
   req.deviation = Slippage;
   req.magic = MagicNumber;
   req.comment = (direction == ORDER_TYPE_BUY) ? "MA+RSI Buy" : "MA+RSI Sell";
   req.type_filling = ORDER_FILLING_IOC;   // Изменено с FOK на IOC для надёжности
   req.type_time = ORDER_TIME_GTC;
   // SL и TP не указываем
   
   if(!OrderSend(req, res))
   {
      if(PrintLog) Print("Ошибка открытия ордера: ", res.retcode, ", ", GetLastError());
      return false;
   }
   ulong ticket = res.order;
   if(PrintLog) Print("Ордер открыт: ", (direction == ORDER_TYPE_BUY) ? "BUY" : "SELL", 
                      " ID=", ticket, " лот=", lot, " цена=", price);
   
   // 2. Теперь модифицируем позицию, добавляя SL и TP
   double sl = 0, tp = 0;
   if(direction == ORDER_TYPE_BUY)
   {
      sl = NormalizePrice(price - slPoints * _Point);
      tp = NormalizePrice(price + tpPoints * _Point);
      if(sl >= price) sl = NormalizePrice(price - (slPoints + 1) * _Point);
      if(tp <= price) tp = NormalizePrice(price + (tpPoints + 1) * _Point);
   }
   else
   {
      sl = NormalizePrice(price + slPoints * _Point);
      tp = NormalizePrice(price - tpPoints * _Point);
      if(sl <= price) sl = NormalizePrice(price + (slPoints + 1) * _Point);
      if(tp >= price) tp = NormalizePrice(price - (tpPoints + 1) * _Point);
   }
   
   // Проверка, что SL и TP отличаются от цены открытия (на случай, если стопы = 0)
   if(sl == price || tp == price)
   {
      if(PrintLog) Print("Ошибка расчёта SL/TP: sl=", sl, " tp=", tp, " цена=", price);
      // Можно попробовать закрыть позицию или просто вернуть true (позиция открыта без стопов)
      return true;
   }
   
   MqlTradeRequest modReq = {};
   MqlTradeResult modRes = {};
   modReq.action = TRADE_ACTION_SLTP;
   modReq.symbol = _Symbol;
   modReq.position = ticket;
   modReq.sl = sl;
   modReq.tp = tp;
   modReq.magic = MagicNumber;
   
   // Несколько попыток модификации (иногда из-за синхронизации первый раз не проходит)
   int attempts = 0;
   while(attempts < 3)
   {
      if(OrderSend(modReq, modRes))
      {
         if(PrintLog) Print("Модификация успешна: SL=", sl, " TP=", tp);
         return true;
      }
      attempts++;
      if(PrintLog) Print("Попытка ", attempts, " модификации не удалась: ", modRes.retcode, ", ", GetLastError());
      Sleep(50); // Небольшая задержка перед повтором (в тестере Sleep работает)
   }
   
   if(PrintLog) Print("Не удалось установить SL/TP после 3 попыток. Позиция оставлена без стопов.");
   return true; // Позиция открыта, но без стопов – это лучше, чем ничего
}

//+------------------------------------------------------------------+
//| Инициализация                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   // Выделяем память под массивы
   ArrayResize(fastMA, 2);
   ArrayResize(slowMA, 2);
   ArrayResize(rsi, 2);
   ArrayResize(adx, 1);
   ArrayResize(atr, 1);
   
   // Устанавливаем серийность (индексацию как в таймсериях)
   ArraySetAsSeries(fastMA, true);
   ArraySetAsSeries(slowMA, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(atr, true);
   
   fastMA_handle = iMA(_Symbol, _Period, FastMAPeriod, 0, (ENUM_MA_METHOD)MAType, (ENUM_APPLIED_PRICE)MAPriceType);
   slowMA_handle = iMA(_Symbol, _Period, SlowMAPeriod, 0, (ENUM_MA_METHOD)MAType, (ENUM_APPLIED_PRICE)MAPriceType);
   rsi_handle = iRSI(_Symbol, _Period, RSIPeriod, PRICE_CLOSE);
   adx_handle = iADX(_Symbol, _Period, ADXPeriod);
   atr_handle = iATR(_Symbol, _Period, ATRPeriod);
   
   if(fastMA_handle == INVALID_HANDLE || slowMA_handle == INVALID_HANDLE ||
      rsi_handle == INVALID_HANDLE || adx_handle == INVALID_HANDLE || atr_handle == INVALID_HANDLE)
   {
      Print("Ошибка создания индикаторов");
      return INIT_FAILED;
   }
   
   // Инициализация защиты
   lastDayCheck = 0;
   peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyStartBalance = peakBalance;
   
   if(PrintLog) Print("Советник инициализирован. Баланс: ", peakBalance);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Деинициализация                                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(fastMA_handle != INVALID_HANDLE) IndicatorRelease(fastMA_handle);
   if(slowMA_handle != INVALID_HANDLE) IndicatorRelease(slowMA_handle);
   if(rsi_handle != INVALID_HANDLE) IndicatorRelease(rsi_handle);
   if(adx_handle != INVALID_HANDLE) IndicatorRelease(adx_handle);
   if(atr_handle != INVALID_HANDLE) IndicatorRelease(atr_handle);
}

//+------------------------------------------------------------------+
//| Основная функция OnTick                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Защита от торговли при превышении лимитов
   if(IsDailyLossExceeded() || IsTotalDrawdownExceeded()) return;
   if(!IsTimeAllowed()) return;
   
   // 2. Трейлинг-стоп (выполняется всегда, если есть позиции)
   UpdateTrailingStops();
   
   // 3. Проверка нового бара
   datetime barTime = iTime(_Symbol, _Period, 0);
   if(barTime != lastBarTime)
   {
      lastBarTime = barTime;
      attemptOnCurrentBar = false;
   }
   
   // 4. Если уже есть позиция или сигнал на этом баре был – выходим
   if(PositionExists() || attemptOnCurrentBar) return;
   
   // 5. Получение данных индикаторов
   if(CopyBuffer(fastMA_handle, 0, 0, 2, fastMA) < 2 ||
      CopyBuffer(slowMA_handle, 0, 0, 2, slowMA) < 2 ||
      CopyBuffer(rsi_handle, 0, 0, 2, rsi) < 2 ||
      CopyBuffer(adx_handle, 0, 0, 1, adx) < 1)
      return;
   
   // 6. Фильтр ADX – торгуем только при сильном тренде
   if(adx[0] < ADXThreshold) return;
   
   // 7. Поиск сигналов
   bool buySignal = (fastMA[1] <= slowMA[1] && fastMA[0] > slowMA[0] && 
                     rsi[0] > RSILowerLevel && rsi[1] <= RSILowerLevel);
   bool sellSignal = (fastMA[1] >= slowMA[1] && fastMA[0] < slowMA[0] && 
                      rsi[0] < RSIUpperLevel && rsi[1] >= RSIUpperLevel);
   
   if(!buySignal && !sellSignal) return;
   
   // 8. Расчёт лота
   double lot = LotFixed;
   if(lot <= 0.0)
   {
      // Нужно определить стоп-лосс в пунктах для расчёта риска
      int slPoints = (int)(ATRMultiplierSL * 10); // временная заглушка, позже пересчитаем через ATR
      if(CopyBuffer(atr_handle, 0, 0, 1, atr) == 1)
         slPoints = (int)MathRound(atr[0] / _Point * ATRMultiplierSL);
      lot = GetLotByRisk(RiskPercent, slPoints);
      if(lot <= 0.0) lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   }
   else
      lot = NormalizeLot(lot);
   
   // 9. Открытие сделки
   attemptOnCurrentBar = true;
   if(buySignal)
      OpenOrder(ORDER_TYPE_BUY, lot, 0, 0); // SL/TP будут вычислены внутри по ATR
   else if(sellSignal)
      OpenOrder(ORDER_TYPE_SELL, lot, 0, 0);
}
//+------------------------------------------------------------------+
