//+------------------------------------------------------------------+
//|                                                robot_rsi_min.mq5 |
//|                                         Copyright 2026, Space-55 |
//+------------------------------------------------------------------+
#property copyright "Space-55"
#property version   "1.12"

input double LotSize = 0.01;
input int StopLoss = 50;
input int TakeProfit = 100;
input int RSIPeriod = 14;
input int RSILevel = 50;

int fastMA_handle, slowMA_handle, rsi_handle;
double fastMA[2], slowMA[2], rsi[2];
MqlTick tick;
ulong magic = 64385;
datetime lastBarTime = 0;
bool attemptOnCurrentBar = false;

//+------------------------------------------------------------------+
int OnInit()
{
   ArraySetAsSeries(fastMA, true);
   ArraySetAsSeries(slowMA, true);
   ArraySetAsSeries(rsi, true);

   fastMA_handle = iMA(_Symbol, _Period, 5, 0, MODE_EMA, PRICE_CLOSE);
   slowMA_handle = iMA(_Symbol, _Period, 12, 0, MODE_EMA, PRICE_CLOSE);
   rsi_handle = iRSI(_Symbol, _Period, RSIPeriod, PRICE_CLOSE);

   if(fastMA_handle==INVALID_HANDLE || slowMA_handle==INVALID_HANDLE || rsi_handle==INVALID_HANDLE)
      return INIT_FAILED;
   return INIT_SUCCEEDED;
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(fastMA_handle!=INVALID_HANDLE) IndicatorRelease(fastMA_handle);
   if(slowMA_handle!=INVALID_HANDLE) IndicatorRelease(slowMA_handle);
   if(rsi_handle!=INVALID_HANDLE) IndicatorRelease(rsi_handle);
}
//+------------------------------------------------------------------+
bool PositionExists()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
      if(PositionGetInteger(POSITION_MAGIC)==magic && PositionGetString(POSITION_SYMBOL)==_Symbol)
         return true;
   return false;
}
//+------------------------------------------------------------------+
bool ValidateLotSize(double &lot)
{
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double stepLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(lot<minLot) lot=minLot;
   if(lot>maxLot) lot=maxLot;
   lot=MathRound(lot/stepLot)*stepLot;
   return true;
}
//+------------------------------------------------------------------+
int GetValidStopLevel(int reqPoints)
{
   long minDist=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   if(reqPoints<minDist)
   {
      Print("Стоп-лосс ",reqPoints," меньше минимального ",minDist,". Установлен ",minDist);
      return (int)minDist;
   }
   return reqPoints;
}
//+------------------------------------------------------------------+
// Правильное округление цены до количества знаков символа
double NormalizePrice(double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
}
//+------------------------------------------------------------------+
void OnTick()
{
   datetime barTime=iTime(_Symbol,_Period,0);
   if(barTime!=lastBarTime)
   {
      lastBarTime=barTime;
      attemptOnCurrentBar=false;
   }
   if(PositionExists() || attemptOnCurrentBar) return;

   if(CopyBuffer(fastMA_handle,0,0,2,fastMA)<2 ||
      CopyBuffer(slowMA_handle,0,0,2,slowMA)<2 ||
      CopyBuffer(rsi_handle,0,0,2,rsi)<2) return;

   // Сигналы
   if(fastMA[1]<=slowMA[1] && fastMA[0]>slowMA[0] && rsi[0]>RSILevel && rsi[1]<=RSILevel)
   {
      attemptOnCurrentBar=true;
      OpenBuyOrder(LotSize,StopLoss,TakeProfit);
   }
   else if(fastMA[1]>=slowMA[1] && fastMA[0]<slowMA[0] && rsi[0]<RSILevel && rsi[1]>=RSILevel)
   {
      attemptOnCurrentBar=true;
      OpenSellOrder(LotSize,StopLoss,TakeProfit);
   }
}
//+------------------------------------------------------------------+
// Открытие ордера без стопов, затем модификация (обход ошибок)
void OpenBuyOrder(double lot, int slPoints, int tpPoints)
{
   if(!ValidateLotSize(lot) || !SymbolInfoTick(_Symbol,tick)) return;

   double price=NormalizePrice(tick.ask);
   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL;
   req.symbol=_Symbol;
   req.volume=lot;
   req.type=ORDER_TYPE_BUY;
   req.price=price;
   req.deviation=10;
   req.magic=magic;
   req.comment="MA+RSI Buy";
   req.type_filling=ORDER_FILLING_IOC;
   req.type_time=ORDER_TIME_GTC;
   // Не ставим SL и TP сразу

   if(!OrderSend(req,res))
   {
      Print("Ошибка BUY (открытие): ",res.retcode,", ",GetLastError());
      return;
   }
   Print("BUY открыт ID ",res.order,", цена ",price);

   // Теперь модифицируем, добавляя SL и TP
   ulong ticket=res.order;
   slPoints=GetValidStopLevel(slPoints);
   tpPoints=GetValidStopLevel(tpPoints);
   double sl=NormalizePrice(price - slPoints*_Point);
   double tp=NormalizePrice(price + tpPoints*_Point);
   // Доп. проверка: SL и TP не должны быть равны цене
   if(sl>=price) sl=NormalizePrice(price - (slPoints+1)*_Point);
   if(tp<=price) tp=NormalizePrice(price + (tpPoints+1)*_Point);

   MqlTradeRequest modReq={};
   MqlTradeResult modRes={};
   modReq.action=TRADE_ACTION_SLTP;
   modReq.symbol=_Symbol;
   modReq.position=ticket;
   modReq.sl=sl;
   modReq.tp=tp;
   modReq.magic=magic;

   if(!OrderSend(modReq,modRes))
      Print("Ошибка модификации BUY: ",modRes.retcode,", ",GetLastError());
   else
      Print("Модификация BUY: SL=",sl," TP=",tp);
}
//+------------------------------------------------------------------+
void OpenSellOrder(double lot, int slPoints, int tpPoints)
{
   if(!ValidateLotSize(lot) || !SymbolInfoTick(_Symbol,tick)) return;

   double price=NormalizePrice(tick.bid);
   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL;
   req.symbol=_Symbol;
   req.volume=lot;
   req.type=ORDER_TYPE_SELL;
   req.price=price;
   req.deviation=10;
   req.magic=magic;
   req.comment="MA+RSI Sell";
   req.type_filling=ORDER_FILLING_IOC;
   req.type_time=ORDER_TIME_GTC;

   if(!OrderSend(req,res))
   {
      Print("Ошибка SELL (открытие): ",res.retcode,", ",GetLastError());
      return;
   }
   Print("SELL открыт ID ",res.order,", цена ",price);

   ulong ticket=res.order;
   slPoints=GetValidStopLevel(slPoints);
   tpPoints=GetValidStopLevel(tpPoints);
   double sl=NormalizePrice(price + slPoints*_Point);
   double tp=NormalizePrice(price - tpPoints*_Point);
   if(sl<=price) sl=NormalizePrice(price + (slPoints+1)*_Point);
   if(tp>=price) tp=NormalizePrice(price - (tpPoints+1)*_Point);

   MqlTradeRequest modReq={};
   MqlTradeResult modRes={};
   modReq.action=TRADE_ACTION_SLTP;
   modReq.symbol=_Symbol;
   modReq.position=ticket;
   modReq.sl=sl;
   modReq.tp=tp;
   modReq.magic=magic;

   if(!OrderSend(modReq,modRes))
      Print("Ошибка модификации SELL: ",modRes.retcode,", ",GetLastError());
   else
      Print("Модификация SELL: SL=",sl," TP=",tp);
}