import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

const navy = Color(0xFF092D55);
const gold = Color(0xFFD7AC49);
const whatsapp = 'https://wa.me/201007247123';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.init();
  runApp(const SanadApp());
}

double amount(Object? x) => (x as num?)?.toDouble() ?? 0;
String money(num n) => '${n.toStringAsFixed(2)} ج';

class Product {
  final int id;
  final String name, barcode;
  final double price, stock;
  Product(this.id, this.name, this.barcode, this.price, this.stock);
  factory Product.from(Map<String, Object?> m) => Product(m['id'] as int,
      m['name'] as String, (m['barcode'] as String?) ?? '', amount(m['price']), amount(m['stock']));
}
class Party {
  final int id;
  final String name, type, phone;
  final double opening;
  Party(this.id, this.name, this.type, this.phone, this.opening);
  factory Party.from(Map<String, Object?> m) => Party(m['id'] as int, m['name'] as String,
      m['type'] as String, (m['phone'] as String?) ?? '', amount(m['opening_balance']));
}
class Line {
  final Product product;
  double quantity, price;
  Line(this.product, {required this.quantity, required this.price});
  double get total => quantity * price;
}

class Store {
  static late Database db;
  static Future<void> init() async {
    db = await openDatabase(p.join(await getDatabasesPath(), 'sanad_v1.db'), version: 3,
      onCreate: (d, v) async {
        await d.execute("CREATE TABLE products(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, barcode TEXT NOT NULL UNIQUE, price REAL NOT NULL, stock REAL NOT NULL DEFAULT 0)");
        await d.execute("CREATE TABLE invoices(id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL, status TEXT NOT NULL, total REAL NOT NULL, stock_applied INTEGER NOT NULL DEFAULT 0)");
        await d.execute("CREATE TABLE invoice_lines(id INTEGER PRIMARY KEY AUTOINCREMENT, invoice_id INTEGER NOT NULL, product_id INTEGER NOT NULL, quantity REAL NOT NULL, price REAL NOT NULL)");
        await d.execute("CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)");
        await d.insert('settings', {'key':'deduct_on_save','value':'false'});
        await d.insert('settings', {'key':'instant_add','value':'true'});
        await _upgrade(d);
        await _upgrade3(d);
      }, onUpgrade: (d, old, now) async { if (old < 2) await _upgrade(d); if (old < 3) await _upgrade3(d); });
  }
  static Future<void> _upgrade(DatabaseExecutor d) async {
    await d.execute("CREATE TABLE IF NOT EXISTS parties(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, type TEXT NOT NULL, phone TEXT NOT NULL DEFAULT '', opening_balance REAL NOT NULL DEFAULT 0)");
    await d.execute("CREATE TABLE IF NOT EXISTS payments(id INTEGER PRIMARY KEY AUTOINCREMENT, party_id INTEGER NOT NULL, amount REAL NOT NULL, created_at TEXT NOT NULL, note TEXT NOT NULL DEFAULT '')");
    await d.execute('ALTER TABLE invoices ADD COLUMN party_id INTEGER');
    await d.execute("ALTER TABLE invoices ADD COLUMN kind TEXT NOT NULL DEFAULT 'sale'");
    await d.execute('ALTER TABLE invoices ADD COLUMN paid REAL NOT NULL DEFAULT 0');
    await d.execute('ALTER TABLE invoices ADD COLUMN previous_balance REAL NOT NULL DEFAULT 0');
  }
  static Future<void> _upgrade3(DatabaseExecutor d) async {
    await d.execute("CREATE TABLE IF NOT EXISTS daily_sheets(id INTEGER PRIMARY KEY AUTOINCREMENT, day TEXT NOT NULL UNIQUE, status TEXT NOT NULL DEFAULT 'draft', approved_at TEXT)");
    await d.execute("CREATE TABLE IF NOT EXISTS daily_lines(id INTEGER PRIMARY KEY AUTOINCREMENT, sheet_id INTEGER NOT NULL, product_id INTEGER NOT NULL, quantity REAL NOT NULL, price REAL NOT NULL, cost REAL NOT NULL DEFAULT 0)");
    await d.execute("CREATE TABLE IF NOT EXISTS expenses(id INTEGER PRIMARY KEY AUTOINCREMENT, day TEXT NOT NULL, description TEXT NOT NULL, amount REAL NOT NULL)");
    await d.execute("ALTER TABLE products ADD COLUMN cost REAL NOT NULL DEFAULT 0");
  }
  static String today() => DateTime.now().toIso8601String().substring(0,10);
  static Future<Map<String,Object?>> sheet(String day) async {
    final found=await db.query('daily_sheets',where:'day=?',whereArgs:[day]);
    if(found.isNotEmpty)return found.first;
    final id=await db.insert('daily_sheets',{'day':day,'status':'draft'},conflictAlgorithm:ConflictAlgorithm.ignore);
    return (await db.query('daily_sheets',where:'day=?',whereArgs:[day])).first;
  }
  static Future<List<Map<String,Object?>>> dailyLines(int id) => db.rawQuery('SELECT l.*,p.name,p.barcode FROM daily_lines l JOIN products p ON p.id=l.product_id WHERE l.sheet_id=? ORDER BY l.id',[id]);
  static Future<void> addDailyLine(int sheetId,int productId,double quantity,double price) async {
    if(quantity<=0||price<0)throw StateError('راجع الكمية والسعر');
    await db.transaction((t) async {
      final sh=(await t.query('daily_sheets',where:'id=?',whereArgs:[sheetId])).first;
      if(sh['status']!='draft')throw StateError('اليومية معتمدة ولا يمكن تعديلها');
      final prod=(await t.query('products',where:'id=?',whereArgs:[productId])).first;
      await t.insert('daily_lines',{'sheet_id':sheetId,'product_id':productId,'quantity':quantity,'price':price,'cost':amount(prod['cost'])});
    });
  }
  static Future<void> deleteDailyLine(int sheetId,int lineId) async {
    await db.transaction((t) async {
      final sh=(await t.query('daily_sheets',where:'id=?',whereArgs:[sheetId])).first;
      if(sh['status']!='draft')throw StateError('اليومية معتمدة');
      await t.delete('daily_lines',where:'sheet_id=? AND id=?',whereArgs:[sheetId,lineId]);
    });
  }
  static Future<void> approveDaily(int sheetId) async {
    await db.transaction((t) async {
      final sh=(await t.query('daily_sheets',where:'id=?',whereArgs:[sheetId])).first;
      if(sh['status']=='approved')return;
      final lines=await t.query('daily_lines',where:'sheet_id=?',whereArgs:[sheetId]);
      final quantities=<int,double>{};
      for(final l in lines){final pid=l['product_id'] as int;quantities[pid]=(quantities[pid]??0)+amount(l['quantity']);}
      for(final entry in quantities.entries){
        final changed=await t.rawUpdate('UPDATE products SET stock=stock-? WHERE id=? AND stock>=?',[entry.value,entry.key,entry.value]);
        if(changed!=1)throw StateError('رصيد المخزون غير كافٍ للصنف رقم ${entry.key}');
      }
      await t.update('daily_sheets',{'status':'approved','approved_at':DateTime.now().toIso8601String()},where:'id=? AND status=?',whereArgs:[sheetId,'draft']);
    });
  }
  static Future<void> addExpense(String day,String description,double value) async {
    if(description.trim().isEmpty||value<=0)throw StateError('راجع بيانات المصروف');
    await db.insert('expenses',{'day':day,'description':description.trim(),'amount':value});
  }
  static Future<List<Map<String,Object?>>> dayInvoices(String day) => db.rawQuery("SELECT i.id,i.total,i.paid,i.kind,COALESCE(p.name,'نقدي') AS customer FROM invoices i LEFT JOIN parties p ON p.id=i.party_id WHERE i.status='approved' AND substr(i.created_at,1,10)=? ORDER BY i.id",[day]);
  static Future<List<Map<String,Object?>>> dayExpenses(String day) => db.query('expenses',where:'day=?',whereArgs:[day],orderBy:'id');
  static Future<List<Product>> products([String query = '']) async => (await db.query('products',
    where: query.trim().isEmpty ? null : 'name LIKE ?', whereArgs: query.trim().isEmpty ? null : ['%${query.trim()}%'], orderBy: 'name')).map(Product.from).toList();
  static Future<Product?> barcode(String code) async {
    final x = await db.query('products', where:'barcode = ?',whereArgs:[code],limit:1);
    return x.isEmpty ? null : Product.from(x.first);
  }
  static Future<Product> product(String name, double price, {String code = '', double stock = 0}) async {
    final clean = name.trim();
    if (clean.isEmpty || price < 0 || stock < 0) throw StateError('راجع بيانات الصنف');
    final rows = await db.query('products',where:'name = ? COLLATE NOCASE',whereArgs:[clean],limit:1);
    if (rows.isNotEmpty) return Product.from(rows.first);
    // A generated internal barcode avoids collisions when users enter products without a barcode.
    final unique = code.trim().isEmpty ? 'SANAD-${DateTime.now().microsecondsSinceEpoch}' : code.trim();
    final id = await db.insert('products',{'name':clean,'barcode':unique,'price':price,'stock':stock});
    return Product(id,clean,unique,price,stock);
  }
  static Future<List<Party>> parties(String type) async => (await db.query('parties',where:'type = ?',whereArgs:[type],orderBy:'name')).map(Party.from).toList();
  static Future<Party> addParty(String name,String type,String phone) async {
    if (name.trim().isEmpty) throw StateError('اكتب اسم الحساب');
    final id = await db.insert('parties',{'name':name.trim(),'type':type,'phone':phone.trim(),'opening_balance':0});
    return Party(id,name.trim(),type,phone.trim(),0);
  }
  static Future<double> balance(int partyId) async {
    final a = await db.rawQuery('SELECT opening_balance FROM parties WHERE id = ?', [partyId]);
    if (a.isEmpty) return 0;
    final inv = await db.rawQuery("SELECT COALESCE(SUM(total-paid),0) AS x FROM invoices WHERE party_id = ? AND status = 'approved'",[partyId]);
    final pay = await db.rawQuery('SELECT COALESCE(SUM(amount),0) AS x FROM payments WHERE party_id = ?',[partyId]);
    return amount(a.first['opening_balance']) + amount(inv.first['x']) - amount(pay.first['x']);
  }
  static Future<void> payment(int partyId,double value) async {
    if (value <= 0) throw StateError('المبلغ غير صحيح');
    await db.insert('payments',{'party_id':partyId,'amount':value,'created_at':DateTime.now().toIso8601String(),'note':''});
  }
  static Future<int> save(List<Line> lines,{required bool approve,required String kind,Party? party,required double paid}) async {
    if (lines.isEmpty) throw StateError('الفاتورة فارغة');
    if (lines.any((l) => l.quantity <= 0 || l.price < 0)) throw StateError('راجع الكميات والأسعار');
    final total = lines.fold<double>(0,(s,l)=>s+l.total);
    if (paid < 0 || paid > total) throw StateError('المدفوع يجب ألا يزيد عن إجمالي الفاتورة');
    if (paid > 0 && party == null && paid < total) throw StateError('اختار العميل أو المورد لتسجيل الباقي');
    final prev = party == null ? 0.0 : await balance(party.id);
    return db.transaction((t) async {
      if (approve && kind == 'sale') {
        for (final l in lines) {
          final r = await t.query('products',columns:['stock'],where:'id = ?',whereArgs:[l.product.id]);
          if (r.isEmpty || amount(r.first['stock']) < l.quantity) throw StateError('رصيد غير كافٍ: ${l.product.name}');
        }
      }
      final id = await t.insert('invoices',{'created_at':DateTime.now().toIso8601String(),
        'status':approve?'approved':'draft','total':total,'stock_applied':approve?1:0,
        'party_id':party?.id,'kind':kind,'paid':paid,'previous_balance':prev});
      for (final l in lines) {
        await t.insert('invoice_lines',{'invoice_id':id,'product_id':l.product.id,'quantity':l.quantity,'price':l.price});
        if (approve) {
          await t.rawUpdate('UPDATE products SET stock = stock + ? WHERE id = ?', [kind=='purchase'?l.quantity:-l.quantity,l.product.id]);
          if(kind=='purchase') await t.update('products',{'cost':l.price},where:'id=?',whereArgs:[l.product.id]);
        }
      }
      return id;
    });
  }
  static Future<void> approve(int id) async {
    await db.transaction((t) async {
      final a = await t.query('invoices',where:'id = ?',whereArgs:[id]);
      if (a.isEmpty) throw StateError('الفاتورة غير موجودة');
      final inv = a.first;
      if (inv['status']=='approved') return;
      final kind = inv['kind'] as String? ?? 'sale';
      final lines = await t.query('invoice_lines',where:'invoice_id = ?',whereArgs:[id]);
      for (final l in lines) {
        final pid = l['product_id'] as int, qty = amount(l['quantity']);
        if (kind == 'sale') {
          final r = await t.query('products',columns:['stock','name'],where:'id = ?',whereArgs:[pid]);
          if (r.isEmpty || amount(r.first['stock']) < qty) throw StateError('رصيد غير كافٍ: ${r.isEmpty?'صنف محذوف':r.first['name']}');
        }
        await t.rawUpdate('UPDATE products SET stock = stock + ? WHERE id = ?', [kind=='purchase'?qty:-qty,pid]);
        if(kind=='purchase')await t.update('products',{'cost':amount(l['price'])},where:'id=?',whereArgs:[pid]);
      }
      await t.update('invoices',{'status':'approved','stock_applied':1},where:'id = ?',whereArgs:[id]);
    });
  }
  static Future<Map<String,Object?>> invoice(int id) async => (await db.query('invoices',where:'id = ?',whereArgs:[id])).first;
  static Future<List<Map<String,Object?>>> invoiceLines(int id) => db.rawQuery('SELECT l.quantity,l.price,p.name FROM invoice_lines l JOIN products p ON p.id=l.product_id WHERE l.invoice_id=?',[id]);
  static Future<String> partyName(Object? id) async {
    if (id == null) return 'نقدي';
    final r = await db.query('parties',columns:['name'],where:'id = ?',whereArgs:[id]);
    return r.isEmpty ? 'حساب غير معروف' : r.first['name'] as String;
  }
}

class SanadApp extends StatefulWidget {
  const SanadApp({super.key});
  @override State<SanadApp> createState() => _SanadAppState();
}
class _SanadAppState extends State<SanadApp> {
  ThemeMode mode = ThemeMode.system;
  @override Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner:false,title:'سند',locale:const Locale('ar'),
    builder:(context,child)=>Directionality(textDirection:TextDirection.rtl,child:child!),
    theme:ThemeData(useMaterial3:true,colorScheme:ColorScheme.fromSeed(seedColor:navy),scaffoldBackgroundColor:const Color(0xFFF5F7FA),
      appBarTheme:const AppBarTheme(backgroundColor:navy,foregroundColor:Colors.white),
      inputDecorationTheme:InputDecorationTheme(border:OutlineInputBorder(borderRadius:BorderRadius.circular(14)))),
    darkTheme:ThemeData(useMaterial3:true,brightness:Brightness.dark,colorScheme:ColorScheme.fromSeed(seedColor:gold,brightness:Brightness.dark),
      appBarTheme:const AppBarTheme(backgroundColor:Color(0xFF071C32),foregroundColor:Colors.white),
      inputDecorationTheme:InputDecorationTheme(border:OutlineInputBorder(borderRadius:BorderRadius.circular(14)))),
  themeMode: mode,
  home: const SplashScreen(),
);
}
class BrandBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  const BrandBar(this.title,{super.key});
  @override Size get preferredSize=>const Size.fromHeight(66);
  @override Widget build(BuildContext context)=>AppBar(title:Row(children:[
    ClipRRect(borderRadius:BorderRadius.circular(9),child:Image.asset('assets/sanad_logo.jpg',height:42,width:42,fit:BoxFit.cover)),
    const SizedBox(width:12),Expanded(child:Text(title,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:19))),
  ]));
}
class HomePage extends StatelessWidget {
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;
  const HomePage({super.key,required this.mode,required this.onMode});
  @override Widget build(BuildContext context)=>Scaffold(appBar:const BrandBar('سند | إدارة أعمالك'),
    body:ListView(padding:const EdgeInsets.all(18),children:[
      Container(padding:const EdgeInsets.all(22),decoration:BoxDecoration(color:navy,borderRadius:BorderRadius.circular(24)),
        child:Column(children:[Image.asset('assets/sanad_logo.jpg',height:110),const SizedBox(height:12),
          const Text('كل أعمالك في سند واحد',style:TextStyle(color:Colors.white,fontSize:23,fontWeight:FontWeight.bold)),
          const SizedBox(height:6),const Text('فواتير • مخزون • عملاء • موردين',style:TextStyle(color:Color(0xFFEAC66B)))])),
      const SizedBox(height:20),
      _go(context,'ورقة اليومية',Icons.edit_note,const DailyPage()),
      _go(context,'فاتورة بيع جديدة',Icons.point_of_sale,const InvoicePage(kind:'sale')),
      _go(context,'فاتورة شراء جديدة',Icons.shopping_cart_checkout,const InvoicePage(kind:'purchase')),
      _go(context,'الأصناف والمخزون',Icons.inventory_2_outlined,const ProductsPage()),
      _go(context,'العملاء والموردون',Icons.groups_outlined,const PartiesPage()),
      _go(context,'الفواتير المحفوظة',Icons.receipt_long,const InvoicesPage()),
      Card(child:ListTile(leading:const Icon(Icons.brightness_6),title:const Text('المظهر'),trailing:DropdownButton<ThemeMode>(value:mode,underline:const SizedBox(),
        items:const [DropdownMenuItem(value:ThemeMode.system,child:Text('تلقائي')),DropdownMenuItem(value:ThemeMode.light,child:Text('فاتح')),DropdownMenuItem(value:ThemeMode.dark,child:Text('داكن'))],onChanged:(v){if(v!=null)onMode(v);}))),
    ]));
  Widget _go(BuildContext c,String name,IconData icon,Widget page)=>Card(margin:const EdgeInsets.only(bottom:10),child:ListTile(
    contentPadding:const EdgeInsets.symmetric(horizontal:16,vertical:9),leading:Icon(icon,color:gold,size:30),
    title:Text(name,style:const TextStyle(fontWeight:FontWeight.w700)),trailing:const Icon(Icons.chevron_left),
    onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>page))));
}


class DailyPage extends StatefulWidget {const DailyPage({super.key});@override State<DailyPage> createState()=>_DailyPageState();}
class _DailyPageState extends State<DailyPage> {
  String day=Store.today(); int? sheetId; bool approved=false; bool busy=false;
  List<Map<String,Object?>> rows=[],invoices=[],expenses=[];
  final name=TextEditingController(), qty=TextEditingController(text:'1'), price=TextEditingController();
  Product? selected; List<Product> matches=[];
  @override void initState(){super.initState();load();}
  @override void dispose(){name.dispose();qty.dispose();price.dispose();super.dispose();}
  Future<void> load() async {
    final sh=await Store.sheet(day), id=sh['id'] as int;
    final r=await Store.dailyLines(id),i=await Store.dayInvoices(day),e=await Store.dayExpenses(day);
    if(mounted)setState((){sheetId=id;approved=sh['status']=='approved';rows=r;invoices=i;expenses=e;});
  }
  void error(Object e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}
  Future<void> search(String value) async {selected=null;final r=await Store.products(value);if(mounted)setState(()=>matches=value.trim().isEmpty?[]:r);}
  void choose(Product p){setState((){selected=p;name.text=p.name;price.text=money(p.price);matches=[];});}
  Future<void> scan() async {
    final code=await Navigator.push<String>(context,MaterialPageRoute(builder:(_)=>const ScanPage()));
    if(code==null)return;
    final p=await Store.barcode(code);
    if(p==null){error('الباركود غير مسجل في المخزن');return;}
    choose(p);
  }
  Future<void> add() async {
    try {
      if(approved||sheetId==null)return;
      final q=double.parse(qty.text.replaceAll(',','.')),p=double.parse(price.text.replaceAll(',','.'));
      final prod=selected??await Store.product(name.text,p);
      await Store.addDailyLine(sheetId!,prod.id,q,p);
      name.clear();qty.text='1';price.clear();selected=null;await load();
    }catch(e){error(e);}
  }
  Future<void> approve() async {
    if(sheetId==null||busy)return;
    setState(()=>busy=true);
    try{await Store.approveDaily(sheetId!);await load();}catch(e){error(e);}finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> addExpense() async {
    final desc=TextEditingController(),value=TextEditingController();
    await showDialog(context:context,builder:(c)=>AlertDialog(title:const Text('إضافة مصروف اليوم'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:desc,decoration:const InputDecoration(labelText:'البيان')),TextField(controller:value,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'المبلغ'))]),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('إلغاء')),FilledButton(onPressed:() async {try{await Store.addExpense(day,desc.text,double.parse(value.text));if(c.mounted)Navigator.pop(c);await load();}catch(e){error(e);}},child:const Text('حفظ'))]));
    desc.dispose();value.dispose();
  }
  Future<void> changeDay() async {
    final date=await showDatePicker(context:context,initialDate:DateTime.parse(day),firstDate:DateTime(2020),lastDate:DateTime(2100));
    if(date!=null){day=date.toIso8601String().substring(0,10);await load();}
  }
  double get retail=>rows.fold(0,(double s,r)=>s+amount(r['quantity'])*amount(r['price']));
  double get wholesale=>invoices.where((i)=>i['kind']=='sale').fold(0,(double s,i)=>s+amount(i['total']));
  double get costs=>rows.fold(0,(double s,r)=>s+amount(r['quantity'])*amount(r['cost']));
  double get expensesTotal=>expenses.fold(0,(double s,e)=>s+amount(e['amount']));
  void info(String title,String content)=>showDialog(context:context,builder:(c)=>AlertDialog(title:Text(title),content:SingleChildScrollView(child:Text(content)),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('إغلاق'))]));
  @override Widget build(BuildContext context)=>Scaffold(appBar:const BrandBar('ورقة اليومية'),body:ListView(padding:const EdgeInsets.all(12),children:[
    Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(children:[Image.asset('assets/sanad_logo.jpg',height:90),const SizedBox(height:8),const Text('﴿وَأَذِّنْ فِي النَّاسِ بِالْحَجِّ يَأْتُوكَ رِجَالًا وَعَلَىٰ كُلِّ ضَامِرٍ يَأْتِينَ مِنْ كُلِّ فَجٍّ عَمِيقٍ﴾',textAlign:TextAlign.center),const Text('سورة الحج: ٢٧',style:TextStyle(fontSize:11)),const SizedBox(height:6),const Text('﴿إِنَّا فَتَحْنَا لَكَ فَتْحًا مُّبِينًا﴾',textAlign:TextAlign.center),const Text('سورة الفتح: ١',style:TextStyle(fontSize:11))]))),
    ListTile(title:const Text('ورقة اليومية'),subtitle:Text(day),leading:const Icon(Icons.calendar_month),trailing:Text(approved?'معتمدة':'مسودة'),onTap:changeDay),
    if(!approved)Card(child:Padding(padding:const EdgeInsets.all(10),child:Column(children:[Row(children:[Expanded(child:TextField(controller:name,onChanged:search,decoration:const InputDecoration(labelText:'الصنف'))),IconButton.filled(onPressed:scan,icon:const Icon(Icons.qr_code_scanner),tooltip:'مسح الباركود')]),
      if(matches.isNotEmpty)SizedBox(height:140,child:ListView(children:matches.map((p)=>ListTile(title:Text(p.name),subtitle:Text('المتاح: ${p.stock}'),onTap:()=>choose(p))).toList())),
      Row(children:[Expanded(child:TextField(controller:qty,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'العدد'))),const SizedBox(width:10),Expanded(child:TextField(controller:price,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'السعر')))]),const SizedBox(height:10),FilledButton.icon(onPressed:add,icon:const Icon(Icons.add),label:const Text('إضافة صنف'))]))),
    Card(child:Column(children:[const ListTile(title:Text('م    |    الصنف    |    العدد × السعر = الإجمالي')),...rows.asMap().entries.map((e)=>ListTile(dense:true,leading:Text('${e.key+1}'),title:Text('${e.value['name']}'),subtitle:Text('${money(amount(e.value['quantity']))} × ${money(amount(e.value['price']))}'),trailing:Row(mainAxisSize:MainAxisSize.min,children:[Text(money(amount(e.value['quantity'])*amount(e.value['price']))),if(!approved)IconButton(onPressed:() async {await Store.deleteDailyLine(sheetId!,e.value['id'] as int);await load();},icon:const Icon(Icons.delete_outline))])))])),
    Card(child:ListTile(title:const Text('إجمالي الإجمالي',style:TextStyle(fontWeight:FontWeight.bold)),trailing:Text(money(retail+wholesale),style:const TextStyle(fontSize:19,fontWeight:FontWeight.bold)))),
    Wrap(spacing:8,children:[OutlinedButton.icon(onPressed:()=>info('ملخص اليوم','مبيعات القطاعي: ${money(retail)}\nفواتير البيع المعتمدة: ${money(wholesale)}\nإجمالي المبيعات: ${money(retail+wholesale)}\nالمصروفات: ${money(expensesTotal)}\nفواتير الجملة: ${invoices.where((i)=>i['kind']=='sale').map((i)=>'#${i['id']} ${i['customer']}: ${money(amount(i['total']))}').join('، ')}'),icon:const Icon(Icons.summarize),label:const Text('ملخص اليوم')),
      OutlinedButton.icon(onPressed:()=>info('حساب المكسب','مبيعات القطاعي: ${money(retail)}\nتكلفة القطاعي المسجلة: ${money(costs)}\nمجمل مكسب القطاعي: ${money(retail-costs)}\nمصروفات اليوم: ${money(expensesTotal)}\nصافي القطاعي بعد المصروفات: ${money(retail-costs-expensesTotal)}\nمهم: ربح فواتير الجملة غير مشمول لحين إضافة تكلفة كل بند وقت البيع.'),icon:const Icon(Icons.trending_up),label:const Text('حساب المكسب')),
      OutlinedButton.icon(onPressed:addExpense,icon:const Icon(Icons.payments),label:const Text('مصروف جديد'))]),
    const SizedBox(height:8),FilledButton.icon(onPressed:approved||busy?null:approve,icon:const Icon(Icons.verified),label:Text(approved?'تم اعتماد اليومية':'اعتماد اليومية وخصم المخزون')),
    const Padding(padding:EdgeInsets.all(10),child:Text('فواتير الجملة المعتمدة تظهر تلقائيًا، ولا يُخصم مخزونها مرة أخرى عند اعتماد اليومية. المصروفات تُسجل منفصلة.',textAlign:TextAlign.center)),
  ]));
}

class ProductsPage extends StatefulWidget {const ProductsPage({super.key});@override State<ProductsPage> createState()=>_ProductsPageState();}
class _ProductsPageState extends State<ProductsPage> {
  List<Product> items=[];
  @override void initState(){super.initState();reload();}
  Future<void> reload() async {final r=await Store.products();if(mounted)setState(()=>items=r);}
  Future<void> add() async {
    final name=TextEditingController(),code=TextEditingController(),price=TextEditingController(),stock=TextEditingController(text:'0');
    await showDialog(context:context,builder:(c)=>AlertDialog(title:const Text('إضافة صنف'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:name,decoration:const InputDecoration(labelText:'اسم الصنف')),const SizedBox(height:8),
      TextField(controller:code,decoration:const InputDecoration(labelText:'باركود (اختياري)')),const SizedBox(height:8),
      TextField(controller:price,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'السعر')),const SizedBox(height:8),
      TextField(controller:stock,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'الرصيد الافتتاحي')),
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('إلغاء')),FilledButton(onPressed:() async {
      try {await Store.product(name.text,double.parse(price.text),code:code.text,stock:double.parse(stock.text));if(c.mounted)Navigator.pop(c);await reload();}
      catch(e){if(c.mounted)ScaffoldMessenger.of(c).showSnackBar(SnackBar(content:Text('$e')));}
    },child:const Text('حفظ'))]));
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:const BrandBar('الأصناف والمخزون'),floatingActionButton:FloatingActionButton(onPressed:add,child:const Icon(Icons.add)),
    body:ListView(children:items.map((x)=>Card(child:ListTile(title:Text(x.name),subtitle:Text('السعر: ${money(x.price)}  •  ${x.barcode.startsWith('SANAD-')?'بدون باركود':x.barcode}'),trailing:Text('الرصيد: ${x.stock}')))).toList()));
}
class ScanPage extends StatefulWidget {const ScanPage({super.key});@override State<ScanPage> createState()=>_ScanPageState();}
class _ScanPageState extends State<ScanPage> {
  bool done=false;
  @override Widget build(BuildContext context)=>Scaffold(appBar:const BrandBar('مسح الباركود'),body:MobileScanner(onDetect:(capture){
    if(done||capture.barcodes.isEmpty)return;
    final v=capture.barcodes.first.rawValue;
    if(v==null||v.isEmpty)return;
    done=true;Navigator.pop(context,v);
  }));
}

class InvoicePage extends StatefulWidget {
  final String kind;
  const InvoicePage({super.key,required this.kind});
  @override State<InvoicePage> createState()=>_InvoicePageState();
}
class _InvoicePageState extends State<InvoicePage> {
  final name=TextEditingController(),qty=TextEditingController(text:'1'),price=TextEditingController(),paid=TextEditingController(text:'0');
  List<Product> matches=[];List<Party> parties=[];Party? selected;Product? product;
  final List<Line> lines=[];bool saving=false;
  String get partyType=>widget.kind=='sale'?'customer':'supplier';
  double get total=>lines.fold(0,(s,l)=>s+l.total);
  @override void initState(){super.initState();load();}
  Future<void> load() async {final p=await Store.parties(partyType);if(mounted)setState(()=>parties=p);}
  void error(Object e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}
  Future<void> search(String s) async {final x=s.trim().isEmpty?<Product>[]:await Store.products(s);if(mounted&&name.text==s)setState(()=>matches=x);}
  void choose(Product x){setState((){product=x;name.text=x.name;price.text=x.price.toString();matches=[];});}
  Future<void> scan() async {
    final code=await Navigator.push<String>(context,MaterialPageRoute(builder:(_)=>const ScanPage()));
    if(code==null)return;
    final x=await Store.barcode(code);
    if(x==null){error('الباركود غير مسجل. يمكنك إضافة الصنف يدويًا.');return;}
    choose(x);
  }
  Future<void> newParty() async {
    final n=TextEditingController(),phone=TextEditingController();
    await showDialog(context:context,builder:(c)=>AlertDialog(title:Text('إضافة ${partyType=='customer'?'عميل':'مورد'}'),content:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:n,decoration:const InputDecoration(labelText:'الاسم')),const SizedBox(height:8),
      TextField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'رقم الهاتف'))]),
      actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('إلغاء')),FilledButton(onPressed:() async {
        try{final x=await Store.addParty(n.text,partyType,phone.text);if(c.mounted)Navigator.pop(c);await load();if(mounted)setState(()=>selected=x);}catch(e){error(e);}
      },child:const Text('إضافة'))]));
  }
  Future<void> addLine() async {
    try{
      final q=double.parse(qty.text.replaceAll(',','.')),pr=double.parse(price.text.replaceAll(',','.'));
      if(q<=0||pr<0||name.text.trim().isEmpty)throw StateError('راجع اسم الصنف والكمية والسعر');
      final x=product??await Store.product(name.text,pr);
      if(!mounted)return;
      setState((){lines.add(Line(x,quantity:q,price:pr));product=null;name.clear();qty.text='1';price.clear();matches=[];});
    }catch(e){error(e);}
  }
  Future<void> save(bool approve) async {
    if(saving)return;
    setState(()=>saving=true);
    try{
      final id=await Store.save(lines,approve:approve,kind:widget.kind,party:selected,paid:double.parse(paid.text.replaceAll(',','.')));
      if(!mounted)return;
      Navigator.pushReplacement(context,MaterialPageRoute(builder:(_)=>InvoiceDetailPage(id:id)));
    }catch(e){error(e);}finally{if(mounted)setState(()=>saving=false);}
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:BrandBar(widget.kind=='sale'?'فاتورة بيع جديدة':'فاتورة شراء جديدة'),
    body:ListView(padding:const EdgeInsets.all(14),children:[
      Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Row(children:[Expanded(child:DropdownButtonFormField<int>(value:selected?.id,decoration:InputDecoration(labelText:partyType=='customer'?'العميل':'المورد'),
          items:parties.map((x)=>DropdownMenuItem(value:x.id,child:Text(x.name))).toList(),onChanged:(id)=>setState(()=>selected=parties.where((x)=>x.id==id).firstOrNull))),
          IconButton(onPressed:newParty,icon:const Icon(Icons.person_add_alt_1),tooltip:'حساب جديد')]),
        const SizedBox(height:12),Row(children:[Expanded(child:TextField(controller:name,onChanged:(s){product=null;search(s);},decoration:const InputDecoration(labelText:'اسم الصنف',prefixIcon:Icon(Icons.search)))),
          const SizedBox(width:8),IconButton.filled(onPressed:scan,icon:const Icon(Icons.qr_code_scanner),tooltip:'مسح الباركود')]),
        if(matches.isNotEmpty)ConstrainedBox(constraints:const BoxConstraints(maxHeight:150),child:ListView(shrinkWrap:true,children:matches.map((x)=>ListTile(title:Text(x.name),subtitle:Text('المخزون: ${x.stock}'),trailing:Text(money(x.price)),onTap:()=>choose(x))).toList())),
        const SizedBox(height:12),Row(children:[Expanded(child:TextField(controller:qty,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'الكمية'))),
          const SizedBox(width:10),Expanded(child:TextField(controller:price,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'سعر الوحدة')))]),
        const SizedBox(height:12),FilledButton.icon(onPressed:addLine,icon:const Icon(Icons.add),label:const Text('إضافة الصنف للفاتورة')),
      ]))),
      const SizedBox(height:10),...lines.asMap().entries.map((e)=>Card(child:ListTile(title:Text(e.value.product.name),subtitle:Text('${e.value.quantity} × ${money(e.value.price)}'),
        trailing:Row(mainAxisSize:MainAxisSize.min,children:[Text(money(e.value.total)),IconButton(onPressed:()=>setState(()=>lines.removeAt(e.key)),icon:const Icon(Icons.delete_outline))])))),
      Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(children:[
        Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('إجمالي الفاتورة',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),Text(money(total),style:const TextStyle(fontWeight:FontWeight.bold,fontSize:19))]),
        const SizedBox(height:10),TextField(controller:paid,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'المدفوع الآن')),
        const SizedBox(height:8),Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('المتبقي من الفاتورة'),Text(money(total-(double.tryParse(paid.text) ?? 0)))]),
      ]))),
      const SizedBox(height:12),Row(children:[Expanded(child:OutlinedButton(onPressed:saving||lines.isEmpty?null:()=>save(false),child:const Text('حفظ مسودة'))),
        const SizedBox(width:10),Expanded(child:FilledButton(onPressed:saving||lines.isEmpty?null:()=>save(true),child:Text(saving?'جارٍ الحفظ...':'اعتماد الفاتورة')))]),
      const SizedBox(height:14),const Text('تحديث المخزون والحسابات يتم عند الاعتماد فقط.',textAlign:TextAlign.center),
    ]));
}

class PartiesPage extends StatefulWidget {const PartiesPage({super.key});@override State<PartiesPage> createState()=>_PartiesPageState();}
class _PartiesPageState extends State<PartiesPage> {
  String type='customer';List<Party> items=[];
  @override void initState(){super.initState();reload();}
  Future<void> reload() async {final x=await Store.parties(type);if(mounted)setState(()=>items=x);}
  Future<void> add() async {
    final n=TextEditingController(),phone=TextEditingController();
    await showDialog(context:context,builder:(c)=>AlertDialog(title:const Text('حساب جديد'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:n,decoration:const InputDecoration(labelText:'الاسم')),
      const SizedBox(height:8),TextField(controller:phone,decoration:const InputDecoration(labelText:'الهاتف'))]),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('إلغاء')),
      FilledButton(onPressed:() async {try{await Store.addParty(n.text,type,phone.text);if(c.mounted)Navigator.pop(c);await reload();}catch(e){if(c.mounted)ScaffoldMessenger.of(c).showSnackBar(SnackBar(content:Text('$e')));}},child:const Text('حفظ'))]));
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const BrandBar('حسابات العملاء والموردين'),
    floatingActionButton: FloatingActionButton(onPressed: add, child: const Icon(Icons.add)),
    body: Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'customer', label: Text('العملاء')),
            ButtonSegment(value: 'supplier', label: Text('الموردون')),
          ],
          selected: {type},
          onSelectionChanged: (selection) {
            setState(() => type = selection.first);
            reload();
          },
        ),
      ),
      Expanded(
        child: ListView(
          children: items.map((party) => FutureBuilder<double>(
            future: Store.balance(party.id),
            builder: (context, snapshot) => Card(
              child: ListTile(
                title: Text(party.name),
                subtitle: Text(party.phone),
                trailing: Text('عليه: ${money(snapshot.data ?? 0)}'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => PartyDetailPage(party: party)),
                ),
              ),
            ),
          )).toList(),
        ),
      ),
    ]),
  );
}
class PartyDetailPage extends StatefulWidget {final Party party;const PartyDetailPage({super.key,required this.party});@override State<PartyDetailPage> createState()=>_PartyDetailPageState();}
class _PartyDetailPageState extends State<PartyDetailPage> {
  Future<void> collect() async {
    final v=TextEditingController();
    await showDialog(context:context,builder:(c)=>AlertDialog(title:Text(widget.party.type=='customer'?'تحصيل من العميل':'سداد للمورد'),content:TextField(controller:v,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'المبلغ')),
      actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('إلغاء')),FilledButton(onPressed:() async {try{await Store.payment(widget.party.id,double.parse(v.text));if(c.mounted)Navigator.pop(c);setState((){});}catch(e){if(c.mounted)ScaffoldMessenger.of(c).showSnackBar(SnackBar(content:Text('$e')));}},child:const Text('تسجيل'))]));
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: BrandBar(widget.party.name),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: collect,
      icon: const Icon(Icons.payments),
      label: const Text('تسجيل دفعة'),
    ),
    body: FutureBuilder<double>(
      future: Store.balance(widget.party.id),
      builder: (context, balanceSnapshot) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                const Text('الرصيد المستحق'),
                Text(
                  money(balanceSnapshot.data ?? 0),
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: gold),
                ),
              ]),
            ),
          ),
          FutureBuilder<List<Map<String, Object?>>>(
            future: Store.db.query(
              'invoices',
              where: 'party_id = ?',
              whereArgs: [widget.party.id],
              orderBy: 'id DESC',
            ),
            builder: (context, invoicesSnapshot) => Column(
              children: (invoicesSnapshot.data ?? []).map((invoice) => ListTile(
                title: Text('فاتورة #${invoice['id']}'),
                subtitle: Text(invoice['status'] == 'approved' ? 'معتمدة' : 'مسودة'),
                trailing: Text(money(amount(invoice['total']))),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => InvoiceDetailPage(id: invoice['id'] as int)),
                ),
              )).toList(),
            ),
          ),
        ],
      ),
    ),
  );
}
class InvoicesPage extends StatefulWidget {const InvoicesPage({super.key});@override State<InvoicesPage> createState()=>_InvoicesPageState();}
class _InvoicesPageState extends State<InvoicesPage> {
  List<Map<String,Object?>> items=[];
  @override void initState(){super.initState();reload();}
  Future<void> reload() async {final x=await Store.db.query('invoices',orderBy:'id DESC');if(mounted)setState(()=>items=x);}
  Future<void> approve(int id) async {try{await Store.approve(id);await reload();}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}}
  @override Widget build(BuildContext context)=>Scaffold(appBar:const BrandBar('الفواتير المحفوظة'),body:ListView(children:items.map((x)=>Card(child:ListTile(
    title:Text('${x['kind']=='purchase'?'شراء':'بيع'} #${x['id']} • ${money(amount(x['total']))}'),subtitle:Text(x['status']=='approved'?'معتمدة':'مسودة'),
    onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>InvoiceDetailPage(id:x['id'] as int))),
    trailing:x['status']=='approved'?const Icon(Icons.verified,color:Colors.green):TextButton(onPressed:()=>approve(x['id'] as int),child:const Text('اعتماد'))))).toList()));
}

class InvoiceDetailPage extends StatelessWidget {
  final int id;
  const InvoiceDetailPage({super.key,required this.id});
  Future<void> printInvoice() async {final bytes=await InvoiceExport.pdf(id);await Printing.layoutPdf(onLayout:(_)=>bytes);}
  Future<void> sharePdf() async {final bytes=await InvoiceExport.pdf(id);final dir=await getTemporaryDirectory();final f=File('${dir.path}/sanad_$id.pdf');await f.writeAsBytes(bytes);await Share.shareXFiles([XFile(f.path)],text:'فاتورة سند #$id');}
  Future<void> shareImage() async {final bytes=await InvoiceExport.pdf(id);final pages=await Printing.raster(bytes,dpi:180).toList();if(pages.isEmpty)throw StateError('تعذر تحويل الفاتورة لصورة');
    final png=await pages.first.toPng();final dir=await getTemporaryDirectory();final f=File('${dir.path}/sanad_$id.png');await f.writeAsBytes(png);await Share.shareXFiles([XFile(f.path)],text:'فاتورة سند #$id');}
  @override Widget build(BuildContext context)=>Scaffold(appBar:BrandBar('فاتورة #$id'),body:FutureBuilder<Uint8List>(future:InvoiceExport.pdf(id),builder:(c,s){
    if(s.hasError)return Center(child:Text('تعذر إنشاء المعاينة: ${s.error}'));
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    return Column(children:[Expanded(child:PdfPreview(build:(_)=>s.data!,canChangePageFormat:false,canChangeOrientation:false,allowPrinting:false,allowSharing:false)),
      Padding(padding:const EdgeInsets.all(12),child:Wrap(spacing:8,runSpacing:8,alignment:WrapAlignment.center,children:[
        FilledButton.icon(onPressed:()=>_run(context,printInvoice),icon:const Icon(Icons.print),label:const Text('طباعة')),
        OutlinedButton.icon(onPressed:()=>_run(context,sharePdf),icon:const Icon(Icons.picture_as_pdf),label:const Text('PDF')),
        OutlinedButton.icon(onPressed:()=>_run(context,shareImage),icon:const Icon(Icons.image),label:const Text('صورة PNG')),
      ]))]);
  }));
  void _run(BuildContext context,Future<void> Function() fn) async {try{await fn();}catch(e){if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}}
}

class InvoiceExport {
  static Future<Uint8List> pdf(int id) async {
    final inv=await Store.invoice(id), lines=await Store.invoiceLines(id);
    final customer=await Store.partyName(inv['party_id']);
    final regular=await PdfGoogleFonts.cairoRegular();
    final bold=await PdfGoogleFonts.cairoBold();
    final logo=await rootBundle.load('assets/sanad_logo.jpg');
    final doc=pw.Document();
    final total=amount(inv['total']),paid=amount(inv['paid']),previous=amount(inv['previous_balance']);
    final isSale=inv['kind']!='purchase';
    pw.Widget cell(String value,{bool heading=false})=>pw.Padding(padding:const pw.EdgeInsets.all(7),child:pw.Text(value,style:pw.TextStyle(font:bold,fontSize:heading?10:9,color:heading?PdfColors.white:PdfColors.black)));
    doc.addPage(pw.MultiPage(pageFormat:PdfPageFormat.a4,theme:pw.ThemeData.withFont(base:regular,bold:bold),textDirection:pw.TextDirection.rtl,
      margin:const pw.EdgeInsets.all(28),build:(ctx)=>[
      pw.Container(padding:const pw.EdgeInsets.all(15),decoration:pw.BoxDecoration(color:PdfColor.fromHex('#092D55'),borderRadius:pw.BorderRadius.circular(12)),
        child:pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[
          pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[pw.Text('سند',style:pw.TextStyle(font:bold,fontSize:28,color:PdfColor.fromHex('#E5BC58'))),
            pw.Text('للمبيعات والمخازن والحسابات',style:pw.TextStyle(font:regular,color:PdfColors.white,fontSize:10)),
            pw.SizedBox(height:8),pw.Text(isSale?'فاتورة مبيعات':'فاتورة مشتريات',style:pw.TextStyle(font:bold,color:PdfColors.white,fontSize:16))]),
          pw.Image(pw.MemoryImage(logo.buffer.asUint8List()),width:85,height:85,fit:pw.BoxFit.contain)])),
      pw.SizedBox(height:18),pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[
        pw.Text('رقم الفاتورة: #$id'),pw.Text('التاريخ: ${(inv['created_at'] as String).split('T').first}')]),
      pw.SizedBox(height:8),pw.Text('${isSale?'العميل':'المورد'}: $customer',style:pw.TextStyle(font:bold,fontSize:13)),
      pw.SizedBox(height:16),
      pw.Table(border:pw.TableBorder.all(color:PdfColors.grey300),columnWidths:{0:const pw.FlexColumnWidth(4),1:const pw.FlexColumnWidth(1.5),2:const pw.FlexColumnWidth(2),3:const pw.FlexColumnWidth(2)},children:[
        pw.TableRow(decoration:pw.BoxDecoration(color:PdfColor.fromHex('#092D55')),children:[cell('الصنف',heading:true),cell('الكمية',heading:true),cell('سعر الوحدة',heading:true),cell('الإجمالي',heading:true)]),
        ...lines.map((l)=>pw.TableRow(children:[cell('${l['name']}'),cell('${l['quantity']}'),cell(money(amount(l['price']))),cell(money(amount(l['price'])*amount(l['quantity'])))]))]),
      pw.SizedBox(height:16),...[
        ['إجمالي الفاتورة',money(total)],['المدفوع',money(paid)],['المتبقي من الفاتورة',money(total-paid)],
        ['الرصيد السابق',money(previous)],['إجمالي المديونية بعد الفاتورة',money(previous+total-paid)]
      ].map((r)=>pw.Padding(padding:const pw.EdgeInsets.symmetric(vertical:4),child:pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[pw.Text(r[0],style:pw.TextStyle(font:bold)),pw.Text(r[1],style:pw.TextStyle(font:bold))]))),
      pw.SizedBox(height:18),pw.Divider(color:PdfColor.fromHex('#D7AC49')),
      pw.Center(child:pw.Text('شكرًا لتعاملكم معنا',style:pw.TextStyle(font:bold,color:PdfColor.fromHex('#092D55'),fontSize:13))),
      pw.SizedBox(height:9),pw.Row(mainAxisAlignment:pw.MainAxisAlignment.center,children:[
        pw.BarcodeWidget(barcode:pw.Barcode.qrCode(),data:whatsapp,width:58,height:58),pw.SizedBox(width:15),
        pw.Column(children:[pw.Text('م. احمد شحاته',style:pw.TextStyle(font:bold)),pw.Text('واتساب: 01007247123',style:pw.TextStyle(font:regular))])]),
      pw.SizedBox(height:5),pw.Center(child:pw.Text('امسح رمز QR لفتح محادثة واتساب مباشرة',style:pw.TextStyle(font:regular,fontSize:8))),
    ]));
    return doc.save();
  }
}class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  int seconds = 5;
  double progress = 0.0;

  @override
  void initState() {
    super.initState();
    startTimer();
  }

  void startTimer() {
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          seconds--;
          progress = (5 - seconds) / 5;
        });
        if (seconds > 0) {
          startTimer();
        } else {
          // بعد 5 ثواني نروح للشاشة الرئيسية
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => HomePage(mode: ThemeMode.system, onMode: (m) {})));
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: navy,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // صورة اللوجو
            Image.asset('assets/sanad_logo.jpg', height: 150),
            const SizedBox(height: 30),
            // العداد التنازلي
            Text('$seconds', style: const TextStyle(color: gold, fontSize: 50, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            const Text('ثواني', style: TextStyle(color: Colors.white, fontSize: 18)),
            const SizedBox(height: 20),
            // شريط التحميل
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 50),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(gold),
                minHeight: 10,
              ),
            ),
            const SizedBox(height: 15),
            const Text('جاري تشغيل التطبيق...', style: TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}
 
