import asyncio
import os
import sqlite3
import re
import json
import logging
from datetime import datetime, timedelta
from aiogram import Bot, Dispatcher, F, types
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup, ReplyKeyboardMarkup, KeyboardButton, WebAppInfo
from aiogram.fsm.storage.memory import MemoryStorage
from apscheduler.schedulers.asyncio import AsyncIOScheduler

# --- НАСТРОЙКА ЛОГИРОВАНИЯ ---
logging.basicConfig(level=logging.INFO)

# --- БАЗА ДАННЫХ ---
DB_PATH = os.getenv("DB_PATH", "bot_database.sqlite")

def db_init():
    try:
        db_dir = os.path.dirname(DB_PATH)
        if db_dir and not os.path.exists(db_dir):
            os.makedirs(db_dir, exist_ok=True)
            
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        cursor.executescript('''
            CREATE TABLE IF NOT EXISTS debts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER, title TEXT, kind TEXT, amount REAL, due_date TEXT, is_paid INTEGER DEFAULT 0);
            CREATE TABLE IF NOT EXISTS goals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER, title TEXT, price REAL, due_date TEXT, saved REAL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS savings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER, amount REAL, source TEXT, date TEXT);
        ''')
        conn.commit()
        conn.close()
        print(f"✅ База данных готова: {DB_PATH}")
    except Exception as e:
        print(f"⚠️ Ошибка БД: {e}")

def db_execute(query, params=()):
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(query, params)
    conn.commit()
    conn.close()

def db_fetchall(query, params=()):
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(query, params)
    rows = cursor.fetchall()
    conn.close()
    return rows

# --- СОСТОЯНИЯ (FSM) ---
class DebtForm(StatesGroup):
    title = State()
    kind = State()
    amount = State()
    date = State()

class GoalForm(StatesGroup):
    title = State()
    price = State()
    date = State()

class SavingForm(StatesGroup):
    amount = State()
    source = State()

class DepositForm(StatesGroup):
    amount = State()

# --- КЛАВИАТУРЫ (Объявлены ДО того, как их используют) ---
def main_menu():
    kb = [
        [KeyboardButton(text="💰 Долги"), KeyboardButton(text="🎯 Цели")],
        [KeyboardButton(text="🏦 Сбережения"), KeyboardButton(text="📊 Статистика")]
    ]
    return ReplyKeyboardMarkup(keyboard=kb, resize_keyboard=True)

def kind_menu():
    kb = [[KeyboardButton(text="Мелкие")], [KeyboardButton(text="Кредиты")]]
    return ReplyKeyboardMarkup(keyboard=kb, resize_keyboard=True, one_time_keyboard=True)

def back_menu():
    return ReplyKeyboardMarkup(keyboard=[[KeyboardButton(text="Отмена")]], resize_keyboard=True, one_time_keyboard=True)

# --- ОСНОВНОЙ КОД ---
bot = Bot(token=os.getenv("BOT_TOKEN"))
dp = Dispatcher(storage=MemoryStorage())

# --- ФОНОВАЯ ЗАДАЧА ---
async def check_reminders():
    tomorrow = (datetime.now() + timedelta(days=1)).strftime('%Y-%m-%d')
    try:
        debts = await asyncio.to_thread(db_fetchall, "SELECT user_id, title, amount, due_date FROM debts WHERE due_date = ? AND is_paid = 0", (tomorrow,))
        goals = await asyncio.to_thread(db_fetchall, "SELECT user_id, title, price, saved, due_date FROM goals WHERE due_date = ?", (tomorrow,))

        for d in debts:
            try:
                await bot.send_message(d[0], f"🔔 Напоминание! Завтра ({d[3]}) срок оплаты долга:\n🔹 {d[1]} — {d[2]} руб.")
            except Exception:
                pass
        for g in goals:
            try:
                await bot.send_message(g[0], f"🔔 Напоминание! Завтра ({g[4]}) дедлайн по цели:\n🎯 {g[1]} (Накоплено {g[3]} из {g[2]} руб.)")
            except Exception:
                pass
    except Exception as e:
        print(f"Ошибка напоминаний: {e}")

async def main():
    await asyncio.to_thread(db_init)
    try:
        scheduler = AsyncIOScheduler()
        scheduler.add_job(check_reminders, 'cron', hour=10, minute=0)
        scheduler.start()
    except Exception as e:
        print(f"Ошибка планировщика: {e}")
        
    print("🚀 Бот запущен...")
    await dp.start_polling(bot)

# --- ПАРСИНГ ДАТЫ ---
def parse_date_smart(text):
    text = text.strip().lower()
    if "завтра" in text:
        return (datetime.now() + timedelta(days=1)).strftime('%Y-%m-%d')
    if "сегодня" in text:
        return datetime.now().strftime('%Y-%m-%d')
    if "через неделю" in text:
        return (datetime.now() + timedelta(days=7)).strftime('%Y-%m-%d')

    clean_text = text.replace('.', '-').replace('/', '-').replace(' ', '')
    formats = ['%Y-%m-%d', '%d-%m-%Y', '%d-%m-%y']
    for fmt in formats:
        try:
            dt = datetime.strptime(clean_text, fmt)
            return dt.strftime('%Y-%m-%d')
        except ValueError:
            continue
    return None

# ================= СТАРТ =================
@dp.message(Command("start"))
async def start(message: types.Message, state: FSMContext):
    await state.clear()
    
    # ⬇️ ВСТАВЬТЕ СЮДА ВАШУ ССЫЛКУ ИЗ GITHUB PAGES ⬇️
    my_app_url = "https://ВАШ_ЛОГИН.github.io/НАЗВАНИЕ_РЕПОЗИТОРИЯ/"
    
    kb = ReplyKeyboardMarkup(
        keyboard=[
            [KeyboardButton(
                text="🚀 Открыть трекер", 
                web_app=WebAppInfo(url=my_app_url)
            )]
        ],
        resize_keyboard=True
    )
    await message.answer("Привет! Нажми на кнопку ниже, чтобы открыть приложение:", reply_markup=kb)

# ================= ОБРАБОТКА ДАННЫХ ИЗ MINI APP =================
@dp.message(F.web_app_data)
async def handle_webapp_data(message: types.Message):
    try:
        data = json.loads(message.web_app_data.data)
        
        if data.get('action') == 'add_debt':
            title = data.get('title', 'Без названия')
            amount = float(data.get('amount', 0))
            due_date = data.get('date')
            
            # Защита от дублирования (если нажали дважды)
            existing = await asyncio.to_thread(
                db_fetchall, 
                "SELECT id FROM debts WHERE user_id = ? AND title = ? AND amount = ?", 
                (message.from_user.id, title, amount)
            )
            
            if not existing:
                await asyncio.to_thread(
                    db_execute, 
                    "INSERT INTO debts (user_id, title, kind, amount, due_date) VALUES (?, ?, ?, ?, ?)",
                    (message.from_user.id, title, "Мелкие", amount, due_date)
                )
            
            # ВОЗВРАЩАЕМ МЕНЮ
            await message.answer(
                f"✅ Долг «{title}» на сумму {amount} руб. сохранен!",
                reply_markup=main_menu()
            )
    except Exception as e:
        await message.answer(f"⚠️ Ошибка при обработке данных: {e}", reply_markup=main_menu())

# ================= КНОПКИ =================
@dp.callback_query(F.data == "go_main_menu")
async def go_to_main_menu(callback: types.CallbackQuery, state: FSMContext):
    await state.clear()
    try:
        await callback.message.delete()
    except Exception:
        pass
    await callback.message.answer("Выбери раздел:", reply_markup=main_menu())
    await callback.answer()

@dp.callback_query(F.data == "add_debt_btn")
async def add_debt_start(callback: types.CallbackQuery, state: FSMContext):
    await state.set_state(DebtForm.title)
    await callback.message.answer("Введи название долга:", reply_markup=back_menu())
    await callback.answer()

@dp.callback_query(F.data.startswith("pay_debt_"))
async def pay_debt(callback: types.CallbackQuery):
    debt_id = int(callback.data.split("_")[2])
    try:
        await asyncio.to_thread(db_execute, "UPDATE debts SET is_paid = 1 WHERE id = ? AND user_id = ?", (debt_id, callback.from_user.id))
        await callback.message.edit_text(f"{callback.message.text}\n\n✅ Долг закрыт!", reply_markup=None)
        await callback.answer("Долг погашен.")
    except Exception:
        await callback.answer("Ошибка или долг уже закрыт.")

@dp.callback_query(F.data.startswith("del_debt_"))
async def delete_debt(callback: types.CallbackQuery):
    debt_id = int(callback.data.split("_")[2])
    try:
        await asyncio.to_thread(db_execute, "DELETE FROM debts WHERE id = ? AND user_id = ?", (debt_id, callback.from_user.id))
        await callback.message.delete()
        await callback.answer("Долг удален!")
    except Exception:
        await callback.answer("Ошибка удаления.")

@dp.callback_query(F.data == "add_goal_btn")
async def add_goal_start(callback: types.CallbackQuery, state: FSMContext):
    await state.set_state(GoalForm.title)
    await callback.message.answer("Введи название цели:", reply_markup=back_menu())
    await callback.answer()

@dp.callback_query(F.data.startswith("dep_goal_"))
async def deposit_goal_start(callback: types.CallbackQuery, state: FSMContext):
    goal_id = int(callback.data.split("_")[2])
    await state.update_data(goal_id=goal_id)
    await state.set_state(DepositForm.amount)
    await callback.message.answer("Введи сумму пополнения:", reply_markup=back_menu())
    await callback.answer()

@dp.callback_query(F.data.startswith("del_goal_"))
async def delete_goal(callback: types.CallbackQuery):
    goal_id = int(callback.data.split("_")[2])
    try:
        await asyncio.to_thread(db_execute, "DELETE FROM goals WHERE id = ? AND user_id = ?", (goal_id, callback.from_user.id))
        await callback.message.delete()
        await callback.answer("Цель удалена!")
    except Exception:
        await callback.answer("Ошибка удаления.")

@dp.callback_query(F.data == "add_sav_btn")
async def add_saving_start(callback: types.CallbackQuery, state: FSMContext):
    await state.set_state(SavingForm.amount)
    await callback.message.answer("Введи сумму:", reply_markup=back_menu())
    await callback.answer()

@dp.callback_query(F.data.startswith("del_sav_"))
async def delete_saving(callback: types.CallbackQuery):
    sav_id = int(callback.data.split("_")[2])
    try:
        await asyncio.to_thread(db_execute, "DELETE FROM savings WHERE id = ? AND user_id = ?", (sav_id, callback.from_user.id))
        await callback.message.delete()
        await callback.answer("Сбережение удалено!")
    except Exception:
        await callback.answer("Ошибка удаления.")

# ================= МЕНЮ =================
@dp.message(F.text == "📊 Статистика")
async def show_stats(message: types.Message):
    try:
        debts = await asyncio.to_thread(db_fetchall, "SELECT SUM(amount) FROM debts WHERE user_id = ? AND is_paid = 0", (message.from_user.id,))
        total_debts = debts[0][0] or 0
        goals_saved = await asyncio.to_thread(db_fetchall, "SELECT SUM(saved) FROM goals WHERE user_id = ?", (message.from_user.id,))
        total_goals_saved = goals_saved[0][0] or 0
        goals_price = await asyncio.to_thread(db_fetchall, "SELECT SUM(price) FROM goals WHERE user_id = ?", (message.from_user.id,))
        total_goals_price = goals_price[0][0] or 0
        savings = await asyncio.to_thread(db_fetchall, "SELECT SUM(amount) FROM savings WHERE user_id = ?", (message.from_user.id,))
        total_savings = savings[0][0] or 0

        text = (
            f"📊 Твоя финансовая сводка:\n\n"
            f"🔴 Активные долги: {total_debts} руб.\n"
            f"🎯 Цели: Накоплено {total_goals_saved} из {total_goals_price} руб.\n"
            f"🏦 Свободные сбережения: {total_savings} руб.\n"
        )
        await message.answer(text)
    except Exception:
        await message.answer("Ошибка при подсчете.")

@dp.message(F.text == "💰 Долги")
async def show_debts(message: types.Message):
    try:
        debts = await asyncio.to_thread(db_fetchall, "SELECT id, title, kind, amount, due_date, is_paid FROM debts WHERE user_id = ?", (message.from_user.id,))
        if not debts:
            await message.answer("У тебя пока нет долгов.")
        else:
            await message.answer("Твои долги:\n")
            for d in debts:
                status = "✅ Оплачен" if d[5] == 1 else f"Срок: {d[4]}"
                text = f"🔹 {d[1]} ({d[2]}) — {d[3]} руб. | {status}"
                kb_list = []
                if d[5] == 0:
                    kb_list.append([InlineKeyboardButton(text="✅ Отметить оплаченным", callback_data=f"pay_debt_{d[0]}")])
                kb_list.append([InlineKeyboardButton(text="🗑 Удалить", callback_data=f"del_debt_{d[0]}")])
                await message.answer(text, reply_markup=InlineKeyboardMarkup(inline_keyboard=kb_list))
    except Exception:
        pass

    add_kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="➕ Добавить долг", callback_data="add_debt_btn")]
    ])
    await message.answer("Что хочешь сделать?", reply_markup=add_kb)

@dp.message(F.text == "🎯 Цели")
async def show_goals(message: types.Message):
    try:
        goals = await asyncio.to_thread(db_fetchall, "SELECT id, title, price, due_date, saved FROM goals WHERE user_id = ?", (message.from_user.id,))
        if not goals:
            await message.answer("У тебя пока нет целей.")
        else:
            await message.answer("Твои цели:\n")
            for g in goals:
                progress = int((g[4] / g[2]) * 100) if g[2] > 0 else 0
                text = f"🎯 {g[1]} — {g[2]} руб. (Срок: {g[3]})\n📈 Накоплено: {g[4]} руб. ({progress}%)"
                kb = InlineKeyboardMarkup(inline_keyboard=[
                    [InlineKeyboardButton(text="💵 Пополнить", callback_data=f"dep_goal_{g[0]}")],
                    [InlineKeyboardButton(text="🗑 Удалить", callback_data=f"del_goal_{g[0]}")]
                ])
                await message.answer(text, reply_markup=kb)
    except Exception:
        pass
        
    add_kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="➕ Добавить цель", callback_data="add_goal_btn")]
    ])
    await message.answer("Что хочешь сделать?", reply_markup=add_kb)

@dp.message(F.text == "🏦 Сбережения")
async def show_savings(message: types.Message):
    try:
        savings = await asyncio.to_thread(db_fetchall, "SELECT id, amount, source, date FROM savings WHERE user_id = ?", (message.from_user.id,))
        if not savings:
            await message.answer("Пока нет записей.")
        else:
            total = sum(s[1] for s in savings)
            await message.answer(f"Всего накоплений: {total} руб.\n")
            for s in savings[-10:]:
                text = f"💰 {s[1]} руб. ({s[2]}) — {s[3]}"
                kb = InlineKeyboardMarkup(inline_keyboard=[
                    [InlineKeyboardButton(text="🗑 Удалить", callback_data=f"del_sav_{s[0]}")]
                ])
                await message.answer(text, reply_markup=kb)
    except Exception:
        pass

    add_kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="➕ Добавить сбережение", callback_data="add_sav_btn")]
    ])
    await message.answer("Что хочешь сделать?", reply_markup=add_kb)

# ================= ВВОД =================
@dp.message(DebtForm.title)
async def add_debt_title(message: types.Message, state: FSMContext):
    if message.text == "Отмена":
        await state.clear()
        return await message.answer("Отменено.", reply_markup=main_menu())
    await state.update_data(title=message.text)
    await message.answer("Выбери тип:", reply_markup=kind_menu())
    await state.set_state(DebtForm.kind)

@dp.message(DebtForm.kind)
async def add_debt_kind(message: types.Message, state: FSMContext):
    if message.text == "Отмена":
        await state.clear()
        return await message.answer("Отменено.", reply_markup=main_menu())
    clean_kind = message.text.strip().lower()
    if clean_kind not in ["мелкие", "кредиты"]:
        return await message.answer("Нажми кнопку 'Мелкие' или 'Кредиты' снизу.")
    await state.update_data(kind=message.text.strip())
    await message.answer("Введи сумму долга:", reply_markup=back_menu())
    await state.set_state(DebtForm.amount)

@dp.message(DebtForm.amount)
async def add_debt_amount(message: types.Message, state: FSMContext):
    if message.text == "Отмена":
        await state.clear()
        return await message.answer("Отменено.", reply_markup=main_menu())
    match = re.search(r'(\d+(?:\.\d+)?)', message.text.replace(',', '.'))
    if not match:
        return await message.answer("Ошибка! Введи число.")
    amount = float(match.group(1))
    await state.update_data(amount=amount)
    await message.answer("Введи срок (ГГГГ-ММ-ДД, ДД.ММ.ГГГГ или 'завтра'):", reply_markup=back_menu())
    await state.set_state(DebtForm.date)

@dp.message(DebtForm.date)
async def add_debt_date(message: types.Message, state: FSMContext):
    if message.text == "Отмена":
        await state.clear()
        return await message.answer("Отменено.", reply_markup=main_menu())
    
    clean_date = parse_date_smart(message.text)
    if not clean_date:
        return await message.answer("❌ Не понял дату. Напиши, например: 2026-12-31, 31.12.2026 или 'завтра'")
    
    try:
        data = await state.get_data()
        await asyncio.to_thread(db_execute, "INSERT INTO debts (user_id, title, kind, amount, due_date) VALUES (?, ?, ?, ?, ?)",
                                 (message.from_user.id, data['title'], data['kind'], data['amount'], clean_date))
        await state.clear()
        await message.answer("Долг сохранен!", reply_markup=main_menu())
    except Exception as e:
        await state.clear()
        await message.answer(f"❌ ОШИБКА ДИСКА: {e}", reply_markup=main_menu())

@dp.message(GoalForm.title)
async def add_goal_title(message: types.Message, state: FSMContext):
    if message.text == "Отмена":
        await state.clear()
        return await message.answer("Отменено.", reply_markup=main_menu())
    await state.update_data(title=message.text)
    await message.answer("Введи цену цели:", reply_markup=back_menu())
    await state.set_state(GoalForm.price)

@dp.message(GoalForm.price)
async def add_goal_price(message: types.Message, state: FSMContext):
    if message.text == "Отмена":
        await state.clear()
        return await message.answer("Отменено.", reply_markup=main_menu())
    match = re.search(r'(\d+(?:\.\d+)?)', message.text.replace(',', '.'))
    if not match:
        return await message.answer("Ошибка! Введи число.")
    price = float(match.group(1))
    await state.update_data(price=price)
    await message.answer("Введи срок (ГГГГ-ММ-ДД, ДД.ММ.ГГГГ или 'завтра'):", reply_markup=back_menu())
    await state.set_state(GoalForm.date)

@dp.message(GoalForm.date)
async def add_goal_date(message: types.Message, state: FSMContext):
    if message.text == "Отмена":
        await state.clear()
        return await message.answer("Отменено.", reply_markup=main_menu())
    
    clean_date = parse_date_smart(message.text)
    if not clean_date:
        return await message.answer("❌ Не понял дату. Напиши, например: 2026-12-31, 31.12.2026 или 'завтра'")
        
    try:
        data = await state.get_data()
        await asyncio.to_thread(db_execute, "INSERT INTO goals (user_id, title, price, due_date) VALUES (?, ?, ?, ?)",
                                 (message.from_user.id, data['title'], data['price'], clean_date))
        await state.clear()
        await message.answer("Цель сохранена!", reply_markup=main_menu())
    except Exception as e:
        await state.clear()
        await message.answer(f"❌ ОШИБКА ДИСКА: {e}", reply_markup=main_menu())

@dp.message(DepositForm.amount)
async def deposit_goal_amount(message: types.Message, state: FSMContext):
    if message.text == "Отмена":
        await state.clear()
        return await message.answer("Отменено.", reply_markup=main_menu())
    match = re.search(r'(\d+(?:\.\d+)?)', message.text.replace(',', '.'))
    if not match:
        return await message.answer("Ошибка! Введи число.")
    amount = float(match.group(1))
    
    try:
        data = await state.get_data()
        await asyncio.to_thread(db_execute, "UPDATE goals SET saved = saved + ? WHERE id = ? AND user_id = ?", (amount, data['goal_id'], message.from_user.id))
        await state.clear()
        await message.answer(f"Ты добавил {amount} руб. к цели!", reply_markup=main_menu())
    except Exception as e:
        await state.clear()
        await message.answer(f"❌ ОШИБКА: {e}", reply_markup=main_menu())

@dp.message(SavingForm.amount)
async def add_saving_amount(message: types.Message, state: FSMContext):
    if message.text == "Отмена":
        await state.clear()
        return await message.answer("Отменено.", reply_markup=main_menu())
    match = re.search(r'(\d+(?:\.\d+)?)', message.text.replace(',', '.'))
    if not match:
        return await message.answer("Ошибка! Введи число.")
    amount = float(match.group(1))
    
    await state.update_data(amount=amount)
    await message.answer("Введи источник:", reply_markup=back_menu())
    await state.set_state(SavingForm.source)

@dp.message(SavingForm.source)
async def add_saving_source(message: types.Message, state: FSMContext):
    if message.text == "Отмена":
        await state.clear()
        return await message.answer("Отменено.", reply_markup=main_menu())
    try:
        data = await state.get_data()
        now = datetime.now().strftime("%Y-%m-%d")
        await asyncio.to_thread(db_execute, "INSERT INTO savings (user_id, amount, source, date) VALUES (?, ?, ?, ?)",
                                 (message.from_user.id, data['amount'], message.text, now))
        await state.clear()
        await message.answer("Сбережение добавлено!", reply_markup=main_menu())
    except Exception as e:
        await state.clear()
        await message.answer(f"❌ ОШИБКА: {e}", reply_markup=main_menu())

# --- ТОЧКА ВХОДА ---
if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, SystemExit):
        print("Бот остановлен.")
