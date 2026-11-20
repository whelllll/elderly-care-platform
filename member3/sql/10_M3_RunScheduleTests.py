"""成员3排班测试驱动：新建专用库；异常时回滚、释放连接、清理本轮用户与夹具。
不删除任何数据库。不改变01—09或业务规则；历史1205记录保留在原v1结果中。
"""
from pathlib import Path
import pyodbc,json,time,threading,concurrent.futures,re,traceback,sys
from datetime import datetime,timezone
pyodbc.pooling=False  # 避免异常模拟用户会话进入连接池
ROOT=Path(__file__).resolve().parent
SOURCE=ROOT  # 仓库内使用同目录正式脚本，不依赖个人绝对路径
DB='Codex_M3_Schedule_'+datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S_%f')
USER='M3_Schedule_DML_Test'
FIXTURE_NAMES=['M3-SCHEDULE-ISO-A','M3-SCHEDULE-ISO-B']
REPORT={'database':DB,'scope':'独立排班规则；合成机构标记不代表跨模块外键合法','checks':[],'cleanup_errors':[],'status':'RUNNING'}
connections=[]
connection_lock=threading.Lock()
created_db=False
ids=[]

class ValidationError(RuntimeError):pass
def require(condition,message):
 if not condition:raise ValidationError(message)

def connect(db):
 conn=pyodbc.connect(f'DRIVER={{ODBC Driver 18 for SQL Server}};SERVER=lpc:.\\SQLEXPRESS;DATABASE={db};Trusted_Connection=yes;Encrypt=yes;TrustServerCertificate=yes;',autocommit=True,timeout=10)
 try:conn.timeout=15
 except BaseException:
  conn.close();raise
 with connection_lock:connections.append(conn)
 return conn

def close_connection(conn,record=True):
 if conn is None:return
 for statement in ['IF XACT_STATE()<>0 ROLLBACK;','REVERT;']:
  try:
   cursor=conn.cursor()
   try:cursor.execute(statement)
   finally:cursor.close()
  except Exception:
   # 连接失效时无法发送回滚，关闭连接由服务器结束事务；后续用新连接清理。
   pass
 try:conn.close()
 except Exception as exc:
  if record:REPORT['cleanup_errors'].append('关闭连接失败：'+str(exc))
 finally:
  with connection_lock:
   connections[:]=[x for x in connections if x is not conn]

def results(cur):
 out=[]
 try:
  while True:
   if cur.description:out.append({'columns':[x[0] for x in cur.description],'rows':[list(r) for r in cur.fetchall()]})
   if not cur.nextset():break
 except Exception:
  REPORT.setdefault('partial_results',[]).append(out)
  raise
 return out

def run(conn,sql):
 cur=conn.cursor()
 try:return results(cur.execute(sql))
 finally:
  try:cur.close()
  except Exception as exc:REPORT['cleanup_errors'].append('释放游标失败：'+str(exc))

def scalar(conn,sql,*args):
 cur=conn.cursor()
 try:
  row=cur.execute(sql,*args).fetchone()
  require(row is not None,'查询没有返回预期结果行')
  return row[0]
 finally:
  try:cur.close()
  except Exception as exc:REPORT['cleanup_errors'].append('释放游标失败：'+str(exc))

def cleanup():
 # 先关闭测试连接，清除未完成事务和EXECUTE AS；失败不阻止后续清理。
 for conn in list(connections):close_connection(conn)
 if not created_db:return  # 绝不进入非本轮新建的已有数据库
 admin=None
 try:
  admin=connect(DB)
  # 按实际查询获得的ID或本轮唯一标记恢复夹具清单，涵盖INSERT成功但取ID失败。
  cur=admin.cursor()
  try:
   if scalar(admin,"SELECT OBJECT_ID(N'dbo.caregiver',N'U')") is not None:
    cur.execute('SELECT caregiver_id FROM dbo.caregiver WHERE caregiver_name IN (?,?)',*FIXTURE_NAMES)
    fixture_ids=set(ids)|{r[0] for r in cur.fetchall()}
    for fixture_id in sorted(fixture_ids):
     try:
      if scalar(admin,"SELECT OBJECT_ID(N'dbo.caregiver_schedule',N'U')") is not None:
       cur.execute('DELETE dbo.caregiver_schedule WHERE caregiver_id=?',fixture_id)
      cur.execute('DELETE dbo.caregiver WHERE caregiver_id=?',fixture_id)
     except Exception as exc:REPORT['cleanup_errors'].append(f'清理夹具{fixture_id}失败：{exc}')
   try:
    cur.execute("IF EXISTS(SELECT 1 FROM sys.database_principals WHERE name=N'M3_Schedule_DML_Test') DROP USER M3_Schedule_DML_Test;")
   except Exception as exc:REPORT['cleanup_errors'].append('删除本轮测试用户失败：'+str(exc))
   cur.execute('SELECT t.name,SUM(p.rows) FROM sys.tables t JOIN sys.partitions p ON p.object_id=t.object_id AND p.index_id IN(0,1) GROUP BY t.name')
   REPORT['final_rows']=[list(r) for r in cur.fetchall()]
   REPORT['test_user_remaining']=scalar(admin,"SELECT COUNT(*) FROM sys.database_principals WHERE name=N'M3_Schedule_DML_Test'")
   if any(r[1]!=0 for r in REPORT['final_rows']) or REPORT['test_user_remaining']!=0:
    REPORT['cleanup_errors'].append('验收库存在残留行或测试用户；请依据日志人工核实，未删库')
  finally:
   try:cur.close()
   except Exception as exc:REPORT['cleanup_errors'].append('释放游标失败：'+str(exc))
 except Exception as exc:REPORT['cleanup_errors'].append('初始化清理连接或查询失败：'+str(exc))
 finally:close_connection(admin)

def main():
 global created_db
 primary=None
 try:
  # 输入读取失败也会进入finally。先读文件，再建立数据库。
  files={n:(SOURCE/n).read_text(encoding='utf-8-sig') for n in ['01_M3_CreateTables.sql','03_M3_Indexes.sql']}
  files.update({n:(ROOT/n).read_text(encoding='utf-8-sig') for n in ['08_M3_ScheduleNoOverlap.sql','06_M3_ConstraintTests-v3.sql','09_M3_ScheduleTests.sql']})
  historical=SOURCE/'evidence/key-results/排班测试原始结果-v1.json'
  require(historical.is_file(),'归档历史证据文件缺失：'+str(historical))
  REPORT['historical_record']={'path':str(historical),'note':'历史验收发生过一次1205；整笔重试后51201，原记录不覆盖。本次发生次数以本次events为准。'}
  master=connect('master')
  try:
   require(scalar(master,'SELECT DB_ID(?)',DB) is None,'数据库已存在，停止，不复用、不覆盖、不删除')
   master.execute(f'CREATE DATABASE [{DB}]')
   created_db=True
  finally:close_connection(master)
  c=connect(DB)
  for n in ['01_M3_CreateTables.sql','03_M3_Indexes.sql']:run(c,files[n])
  run(c,files['08_M3_ScheduleNoOverlap.sql'])
  if '--schedule-only' not in sys.argv:
   # 同一连接连续执行v3两轮，沿用开头及结尾清理，不再运行历史失败版。
   for attempt in (1,2):
    r=run(c,files['06_M3_ConstraintTests-v3.sql'])
    detail=next(x for x in r if x['columns']==['id','name','expected','actual','status'])
    require(len(detail['rows'])==59 and all(x[-1]=='PASS' for x in detail['rows']),'06回归数量或PASS状态不符')
    require(tuple(c.execute("SELECT OBJECT_ID('tempdb..#caregiver'),OBJECT_ID('tempdb..#Results')").fetchone())==(None,None),'06存在临时表残留')
    REPORT['checks'].append({'name':f'06-v3同连接第{attempt}轮','pass':59,'fail':0,'case_results':detail['rows']})
  else:
   REPORT['checks'].append({'name':'06回归','status':'NOT_RERUN','reason':'显式指定schedule-only，本轮未执行06-v3，不能计为59项通过'})
  # 隔离合成护工仅用于排班测试；不拿该org_id冒充机构真实主键。
  for name in ['M3-SCHEDULE-ISO-A','M3-SCHEDULE-ISO-B']:
   ids.append(c.execute("SET NOCOUNT ON; INSERT dbo.caregiver(caregiver_name,org_id,phone,service_area) VALUES(?,-2147483648,'00000000000',N'隔离排班测试社区'); SELECT CONVERT(int,SCOPE_IDENTITY());",name).fetchone()[0])
  s=files['09_M3_ScheduleTests.sql'].replace('@TestCaregiverID int=NULL,@OtherCaregiverID int=NULL',f'@TestCaregiverID int={ids[0]},@OtherCaregiverID int={ids[1]}')
  r=run(c,s);detail=next(x for x in r if x['columns']==['id','name','status','detail'])
  require(len(detail['rows'])==18 and all(x[2]=='PASS' for x in detail['rows']),'18项排班用例不通过：'+str(detail))
  REPORT['single_connection']=detail['rows']
  # 两条独立连接：A插入后保持未提交；B提交重叠插入请求；确认B未完成后释放A。
  REPORT['concurrency']=[]
  insert="INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(?,'20320105 08:00:00','20320105 12:00:00',2);"
  for trial in range(1,4):
   a=connect(DB)
   try:
    a.execute('BEGIN TRAN');a.execute(insert,ids[0])
   except Exception:
    close_connection(a);raise
   entered=threading.Event()
   def contender():
    b=None;start=time.monotonic()
    try:
     b=connect(DB);entered.set()
    except Exception:
     entered.set();raise
    try:
     b.execute('BEGIN TRAN');b.execute(insert,ids[0]);b.execute('COMMIT');return {'result':'UNEXPECTED_COMMIT'}
    except pyodbc.Error as e:
     try:b.execute('IF XACT_STATE()<>0 ROLLBACK;')
     except pyodbc.Error:pass
     return {'result':'REJECTED','message':str(e),'seconds':round(time.monotonic()-start,3)}
    finally:close_connection(b)
   pool=concurrent.futures.ThreadPoolExecutor(max_workers=1)
   try:
    f=pool.submit(contender);require(entered.wait(10),'并发B未能进入连接阶段');time.sleep(.6)
    if f.done():f.result()  # 优先报告工作线程的真实初始化异常
    blocked=not f.done();a.execute('COMMIT');result=f.result(timeout=20)
   finally:
    close_connection(a)  # 先释放A的锁，再等待B结束，避免异常退出时互相等待
    pool.shutdown(wait=True,cancel_futures=True)
   count=c.execute('SELECT COUNT(*) FROM dbo.caregiver_schedule WHERE caregiver_id=?',ids[0]).fetchone()[0]
   require(blocked and result['result']=='REJECTED' and '51201' in result['message'] and count==1,'等待型并发验收失败：'+str(result))
   REPORT['concurrency'].append({'trial':trial,'second_waited':blocked,'committed_rows':count,**result})
   c.execute('DELETE dbo.caregiver_schedule WHERE caregiver_id=?',ids[0])
  # 同时起跑，无先后插入保证：若遇1205整笔事务重试，再核对冲突51201和最终单条。
  REPORT['simultaneous']=[]
  for trial in range(1,4):
   barrier=threading.Barrier(2)
   def race():
    b=None;events=[]
    try:
     b=connect(DB);barrier.wait(timeout=10)
     for retry in range(4):
      try:b.execute('BEGIN TRAN');b.execute(insert,ids[0]);b.execute('COMMIT');return {'outcome':'COMMIT','events':events}
      except pyodbc.Error as e:
       try:b.execute('IF XACT_STATE()<>0 ROLLBACK;')
       except pyodbc.Error:pass
       events.append(str(e))
       if '51201' in str(e):return {'outcome':'CONFLICT','events':events}
       if '1205' not in str(e):raise
       time.sleep(.1*(retry+1))
     raise RuntimeError('死锁重试耗尽，测试不能计通过')
    finally:close_connection(b)
   with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    fs=[pool.submit(race),pool.submit(race)];r=[f.result(timeout=30) for f in fs]
   count=c.execute('SELECT COUNT(*) FROM dbo.caregiver_schedule WHERE caregiver_id=?',ids[0]).fetchone()[0]
   require(sorted(x['outcome'] for x in r)==['COMMIT','CONFLICT'] and count==1,'同时起跑并发验收失败：'+str(r))
   REPORT['simultaneous'].append({'trial':trial,'rows':count,'sessions':r})
   c.execute('DELETE dbo.caregiver_schedule WHERE caregiver_id=?',ids[0])
  # 真实低权限用户只能DML，不能禁用触发器。
  c.execute("CREATE USER M3_Schedule_DML_Test WITHOUT LOGIN;")
  c.execute("GRANT SELECT,INSERT,UPDATE,DELETE ON dbo.caregiver_schedule TO M3_Schedule_DML_Test; GRANT SELECT ON dbo.caregiver TO M3_Schedule_DML_Test; DENY ALTER ON dbo.caregiver_schedule TO M3_Schedule_DML_Test;")
  c.execute(insert,ids[0]);c.execute("EXECUTE AS USER=N'M3_Schedule_DML_Test';")
  try:
   try:c.execute('DISABLE TRIGGER dbo.TR_M3_Schedule_NoOverlap ON dbo.caregiver_schedule;');raise ValidationError('低权限用户禁用触发器成功')
   except pyodbc.Error as e:
    require(any(code in str(e) for code in ['(1088)','(15151)','(229)']),'禁用操作未返回预期权限错误：'+str(e));REPORT['cannot_disable']=str(e)
   try:c.execute(insert,ids[0]);raise ValidationError('低权限直写绕过规则')
   except pyodbc.Error as e:require('51201' in str(e),'低权限DML没有返回51201：'+str(e));REPORT['direct_dml_blocked']=str(e)
  finally:
   try:c.execute('REVERT;')
   except Exception as exc:
    REPORT['cleanup_errors'].append('恢复测试用户会话失败：'+str(exc))
    close_connection(c)  # 不掩盖原验收异常；由fresh admin完成剩余清理
  if any(x is c for x in connections):c.execute('DROP USER M3_Schedule_DML_Test;')

 except BaseException as exc:
  primary=exc
  REPORT['error']={'type':type(exc).__name__,'message':str(exc),'traceback':traceback.format_exc()}
 finally:
  cleanup()
  REPORT['status']='FAILED' if primary is not None or REPORT['cleanup_errors'] else 'PASSED'
  REPORT['connections_remaining']=len(connections)
  if REPORT['connections_remaining']:
   REPORT['cleanup_errors'].append('连接跟踪清单非空');REPORT['status']='FAILED'
  try:
   (ROOT/f'schedule_execution_{DB}.json').write_text(json.dumps(REPORT,ensure_ascii=False,indent=2),encoding='utf8')
  except Exception as exc:
   REPORT['cleanup_errors'].append('保存结果失败：'+str(exc));REPORT['status']='FAILED'
  print(json.dumps(REPORT,ensure_ascii=False,indent=2))
 if primary is not None:raise primary
 if REPORT['cleanup_errors']:raise RuntimeError('测试清理或结果保存失败，必须检查cleanup_errors，不能计为通过')

if __name__=='__main__':main()
