-- Start of DDL Script for Package Body DEPSTAT.EMAILREADER
-- Generated 23/10/2012 16:42:41 from DEPSTAT@BISDB

-- Drop the old instance of EMAILREADER
DROP PACKAGE emailreader
/

CREATE OR REPLACE 
PACKAGE emailreader
authid current_user
  IS
-- Чтение писем из почты
--
-- Author = sparshukov   
-- ---------  ----------  ------------------------------------------
--            10/11/2011  первоначальные наброски
--            17/01/2012  CmdCnt, LoginImap, LogoutImap
-- ---------  ----------  ------------------------------------------
   g_sender         varchar2(50)     := '<autoreport@megafonkavkaz.ru>';
   g_mailhost       VARCHAR2(50)     := 'mailr1.lan.megafonkavkaz.ru';
   g_mail_conn      utl_smtp.connection;
   g_message        varchar2(4000)   := NULL;
   g_mailBoundary  varchar2(50) := 'mailpartPsv3';
--------------------------------------------------------------------------------
   res_success   number := 1;
   res_continue  number := 0;
   res_error     number :=-1;
--------------------------------------------------------------------------------
  TYPE t_string_table IS TABLE OF VARCHAR2(32767);
  g_reply       t_string_table := t_string_table();
  g_reply_status varchar2(10);
  g_lastStackMsg number :=0;
--------------------------------------------------------------------------------

  FUNCTION loginImap (p_host  IN  VARCHAR2,
                  p_user  IN  VARCHAR2,
                  p_pass  IN  VARCHAR2,
                  p_port  IN  PLS_INTEGER default 143
                 ) RETURN UTL_TCP.connection;
  PROCEDURE logoutImap(p_conn   IN OUT NOCOPY  UTL_TCP.connection);


  function SelectPathImap(p_conn   IN OUT NOCOPY  UTL_TCP.connection, p_box number, p_path in number) return number;
  function g_checkBox(p_box   number default null)return number;

  procedure loadHeaders(p_conn   IN OUT NOCOPY  UTL_TCP.connection, p_box in number, p_path in number);
  function FindInAnswerToken(p_startToken varchar2, p_stopToken varchar2 default ':')return varchar2;
  function FindInAnswer(p_string varchar2, p_pattern varchar2, 
      p_position  number default 1,
      p_occur     number default 1,
      p_mathparam vARCHAR2 default 'i',
      p_subexpr   number default 0 )return varchar2;
  function decode_rfc2047(p_str in varchar2) return varchar2;
  function FindInAnswerN(p_string varchar2, p_pattern varchar2, 
  p_position  number default 1,
  p_occur     number default 1,
  p_mathparam vARCHAR2 default 'i',
  p_subexpr   number default 0
)return number;
  function ExtractN(p_string varchar2, 
  p_pattern   varchar2, 
  p_position  number    default 1,
  p_occur     number    default 1,
  p_mathparam vARCHAR2  default 'i',
  p_subexpr   number    default 0
)return number;
END;
/*
выполнение расчета 
	- по джобу номер 5
	- по имени процесса
	- по примеру (пересылка прошлого письма)

загрузка данных из вложения

Ответ о статусе процесса
	- когда последний раз был выполнен
	- кому был предоставлен


1) загрузка сведений по трафику визитеров от москвы, выполнение процесса анализа, отправка результатов работы
2) загрузка сведений по абонентам получившим призы для учета в персонифицированном учете
3)*/
/


CREATE OR REPLACE 
PACKAGE BODY emailreader
IS

  l_debug       number := 1;
--  l_debug_supress number :=0;
  g_CmtCounter  number := 0;
  g_unreadCount number := 0;
  g_hasUnseen   number := 0;
--------------------------------------------------------------------------------
  g_clob        clob;

  TYPE t_number_table IS TABLE OF number;
  emailList t_number_table := t_number_table();

  tcp_connect_closed EXCEPTION; -- network error: TNS:connection closed
  PRAGMA EXCEPTION_INIT (tcp_connect_closed, -29260);
  
--------------------------------------------------------------------------------
-- вспомогательные процедурки
--------------------------------------------------------------------------------
procedure debugmsg(msg in varchar2, p_debug_supress number default 0)
is
  l_has_ora number;
  l_debug_supress   number  := p_debug_supress;
begin
  l_has_ora := instr(msg,'ORA-');
  if l_has_ora > 0 then 
    l_debug_supress :=0;
  end if;
  if l_debug=1 and (l_debug_supress=0) then
    log_ovart(case when l_has_ora>0 then -1 else 0 end, 'emailreader', msg);
  end if;
end;

--------------------------------------------------------------------------------
procedure dumpstack(P_from in number default null)
is
  l_from number;
begin
  l_from := nvl(p_from, g_reply.first);
  dbms_output.put_line('---start of stack--('||case when p_from is null then 'с начала'else to_char(l_from)end||')---------');
  for i in l_from .. g_reply.last
  loop
    dbms_output.put_line(i||': '||g_reply(i));
  end loop;
  dbms_output.put_line('---------------------------');
  dbms_output.put_line('total '||to_char(g_reply.last-l_from)||' records');
  dbms_output.put_line('----end of stack-----------');
end;

--------------------------------------------------------------------------------
function decode_rfc2047(p_str in varchar2) return varchar2
is
  l_err     varchar2(2000);
  q_str     varchar2(2000);
  l_str     varchar2(1000):=p_str;
begin
  for i in 
  (
    select mimestr, pos, case when pos>0 then utl_encode.mimeheader_decode(replace(mimestr,'_','=20')) 
                                         else utl_encode.mimeheader_decode(mimestr) end decodestr
    from (
            select t.mimestr, instr(t.mimestr,'?Q?')pos from 
            (
                select '=?'||regexp_substr(ui, '=\?([^?]+\?[BQ][?][^?]+)\?' ,1,level,'i', 1)||'?=' mimestr 
                from (select l_str ui from dual)
                connect by level<=10
            ) t
            where mimestr <> '=??='
         )
  )
  loop
    l_str := replace(l_str, i.mimestr, i.decodestr);
  end loop;
  return l_str;
exception
  when others then 
    l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
    debugmsg(l_err);
    return null;
end;

--------------------------------------------------------------------------------
function FindLastReply return clob
is
  ts   clob;
  nr   number := 0;
begin
  dbms_lob.createtemporary(ts,false);
  for i in g_lastStackMsg .. g_reply.last
  loop
     if nr<>0 then 
       dbms_lob.writeappend(ts, 2, chr(13)||chr(10)); 
     end if;
--     dbms_output.put_line('write : '||g_reply(i));
     if g_reply(i) is not null then 
       dbms_lob.writeappend(ts, length(g_reply(i)), g_reply(i)); 
     end if;
     nr := nr+1;
  end loop;
  return ts;
end;

--------------------------------------------------------------------------------
function FindInAnswerToken(p_startToken varchar2, p_stopToken varchar2 default ':') return varchar2
is
  l_err varchar2(2000);
  l_value varchar2(3000);
  l_start_pos   number :=0;
  l_linecarryout number;
  l_startToken  varchar2(100) := upper(p_startToken);
  l_stopToken   varchar2(100) := ':'; --upper(p_stopToken);
begin
--  dbms_output.put_line('==start='||l_startToken||'==stop='||l_stopToken||'========================================== ');
  for i in g_lastStackMsg .. g_reply.last
  loop
--    dbms_output.put_line('== итерация '||i||'========================================== ');
    l_linecarryout := 0;
    if l_start_pos=0 then 
      l_start_pos := instr( upper(g_reply(i)), l_startToken);
      if l_start_pos>0  then 
        l_value := substr(g_reply(i), l_start_pos+length(p_startToken)+1);
        l_linecarryout :=1;
        continue;
      end if;
    end if;
    
    if l_start_pos>0 and g_reply(i) is null then 
      return trim(l_value);
    end if;
    if l_start_pos>0 and substr(g_reply(i),1,1)not in (' ',chr(9)) then 
      if instr(upper(g_reply(i)), l_stopToken)>0 then 
        return trim(l_value);
      end if;
    end if;
    
    if l_linecarryout=0 and l_start_pos>0 then 
      l_value := l_value||trim(g_reply(i));
    end if;
  end loop;
  
  return trim(l_value);
exception
  when others then
    l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
    debugmsg(l_err);
    return null;
end;

--------------------------------------------------------------------------------
function FindInAnswerD(p_string varchar2, p_pattern varchar2, p_DTFormat varchar2, p_nls varchar2,
  p_position  number default 1,
  p_occur     number default 1,
  p_mathparam vARCHAR2 default 'i',
  p_subexpr   number default 0
)return timestamp with time zone
is
  l_err       varchar2(3000):= '';
  l_date_tz   timestamp with time zone;
begin
  l_err := FindInAnswer(p_string, p_pattern,p_position, p_occur, p_mathparam, p_subexpr);
  select to_timestamp_tz(l_err, p_DTFormat, p_nls) into l_date_tz from dual;
  return l_date_tz;
exception
  when others then
    l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
    debugmsg(l_err);
    return null;
end;

--------------------------------------------------------------------------------
function ExtractN(p_string varchar2, 
  p_pattern   varchar2, 
  p_position  number    default 1,
  p_occur     number    default 1,
  p_mathparam vARCHAR2  default 'i',
  p_subexpr   number    default 0
)return number
is
  l_err       varchar2(2000):= '';
begin
  l_err := regexp_substr(p_string, p_pattern,p_position, p_occur, p_mathparam, p_subexpr);
  return to_number(l_err);
exception
  when others then
    l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
    debugmsg(l_err);
    return null;
end;

--------------------------------------------------------------------------------
function FindInAnswerN(p_string varchar2, p_pattern varchar2, 
  p_position  number default 1,
  p_occur     number default 1,
  p_mathparam vARCHAR2 default 'i',
  p_subexpr   number default 0
)return number
is
  l_err       varchar2(3000):= '';
begin
  return to_number(FindInAnswer(p_string, p_pattern,p_position, p_occur, p_mathparam, p_subexpr));
exception
  when others then
    l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
    debugmsg(l_err);
    return null;
end;

--------------------------------------------------------------------------------
function FindInAnswer(p_string varchar2, p_pattern varchar2, 
  p_position  number default 1,
  p_occur     number default 1,
  p_mathparam vARCHAR2 default 'i',
  p_subexpr   number default 0
)return varchar2
is
  l_value varchar2(1000);
  l_err   varchar2(2000);
begin
  for i in g_lastStackMsg .. g_reply.last
  loop
--    dbms_output.put_line('---------------- строка '||i||' -----------------');
    if upper(g_reply(i)) like upper(p_string) then 
--      dbms_output.put_line('---------------- найдена строка под паттерн -----------------');
      l_value := regexp_substr(g_reply(i), p_pattern, p_position, p_occur, p_mathparam, p_subexpr);
        return trim(l_value);
    end if;
  end loop;
  return trim(l_value);
exception
  when others then
    l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
    debugmsg(l_err);
    return null;
end;

--------------------------------------------------------------------------------
function CmdCnt return varchar2
is
begin
  g_CmtCounter := g_CmtCounter+1;
  return upper(substr(sys_context('userenv','server_host'),1,1))||trim(to_char(g_CmtCounter,'0000'));
end;

--------------------------------------------------------------------------------
-- зачитывает ответ, если он есть
PROCEDURE get_reply (p_conn  IN OUT NOCOPY  UTL_TCP.connection, p_debug_supress in number default 0, p_use_gclob number default 0) 
IS
  l_reply_cmd  VARCHAR2(200) := NULL;
  l_line       VARCHAR2(1000):= NULL;
  l_err        varchar2(3000):= '';
  l_cnt        number        := 0; --счетчик считанных строк
  l_tail       number;
BEGIN
  g_reply_status := null; -- сбрасываем статус
  l_tail := g_reply.Last; -- идентифицируем последнюю запись в стеке
  -- усекаем спец.цлоб с ответом, при необходимости
  if p_use_gclob=1 then   
    dbms_lob.trim(g_clob,0);
  end if;
  -- зачитываем строки из открытого порта
  LOOP
    l_line := UTL_TCP.get_line(p_conn, TRUE);
    l_cnt  := l_cnt + 1;
    if p_use_gclob=1 then 
      -- если ответ машрутизируется в спец.цлоб
      if l_cnt=1 then g_reply.extend; g_reply(g_reply.last) := l_line; end if;
      dbms_lob.writeAppend(g_clob, length(l_line), l_line);
    else
      -- если ответ идет стандартный лог
      g_reply.extend; g_reply(g_reply.last) := l_line;
      debugmsg('g_reply ('||l_line||')', p_debug_supress);
    end if;
  END LOOP;
EXCEPTION
  WHEN UTL_TCP.END_OF_INPUT     THEN null;
  when utl_tcp.TRANSFER_TIMEOUT then 
    -- корректируем хвостик на последний ответ
    if l_tail<> g_reply.last then g_lastStackMsg:=l_tail+1; end if;     
    -- записываем в обычный лог последнюю строку ответа направленного в спец.цлоб
    if p_use_gclob=1 and l_tail<> g_reply.last then g_reply.extend; g_reply(g_reply.last) := l_line; end if;
    -- в последней строке ищем описание статуса ответа
    g_reply_status := regexp_substr(l_line,' (OK|NO|BAD|PREAUTH|ERROR|BYE)',1,1,'',1);
  when others then 
    l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
    debugmsg(l_err);
END;

--------------------------------------------------------------------------------
PROCEDURE send_command (p_conn     IN OUT NOCOPY  UTL_TCP.connection,
                        p_command  IN             VARCHAR2,
                        p_debug_supress in        number    default 0,
                        p_use_gclob               number    default 0) 
IS
  l_result  PLS_INTEGER;
  l_err     varchar2(3000):= '';
BEGIN
  get_reply (p_conn); -- по протоколу сервер может передать данные клиенту без запроса с его стороны
--  debugmsg('try command('||p_command||')');
  l_result := UTL_TCP.write_line(p_conn, p_command);
  get_reply(p_conn, p_debug_supress, p_use_gclob);
exception
  when tcp_connect_closed then /*: network error: TNS:connection closed*/
    l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
    debugmsg(l_err);
    debugmsg('Регенерирую Exception для выхода наружу');
    raise;
  when others then
    l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
    debugmsg(/*'ошибка при отправке команды ('||p_command||') '||*/l_err);
END;


--==============================================================================
-- логика
--------------------------------------------------------------------------------
FUNCTION loginImap (p_host  IN  VARCHAR2,
                p_user  IN  VARCHAR2,
                p_pass  IN  VARCHAR2,
                p_port  IN  PLS_INTEGER default 143
                ) RETURN UTL_TCP.connection 
IS
  l_err    varchar2(3000)  := '';
  l_conn   UTL_TCP.connection;
  l_Host   varchar2(200)   := p_host;
  l_user   varchar2(200)   := p_user;
  l_Pass   varchar2(200)   := p_pass;
BEGIN
  debugmsg('--------- loginImap()');
  g_reply.delete;
  l_conn := UTL_TCP.open_connection(l_host, p_port, tx_timeout => 1);
--  l_conn.tx_timeout := 5;
  send_command(l_conn, CmdCnt||' LOGIN ' || l_user ||' '||l_pass);
  if g_reply_status<>'OK' then 
    debugmsg('первый логин - неуспешный');
    send_command(l_conn, CmdCnt||' LOGIN ' || l_user ||' '||l_pass);
  end if;
  if g_reply_status='OK' then 
    debugmsg('соединение установлено');
    g_hasUnseen := 0;
    return l_conn;
  else
    utl_tcp.CLOSE_CONNECTION(l_conn);
    return null;
  end if;
exception
  when others then
    l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
    debugmsg(l_err);
    return null;  
END;

--------------------------------------------------------------------------------
PROCEDURE logoutImap(p_conn   IN OUT NOCOPY  UTL_TCP.connection) 
AS
  l_dat  date;
BEGIN
  debugmsg('--------- logoutImap()');
  send_command(p_conn, CmdCnt||' LOGOUT');
  UTL_TCP.close_connection(p_conn);
END;


--------------------------------------------------------------------------------
-- открывает указанную папку для чтения.
-- проверяет UIDVALIDITY текущий и от последнего сеанса
-- возвращает флаг - есть ли непрочтенные сообщения
function SelectPathImap(p_conn   IN OUT NOCOPY  UTL_TCP.connection,p_box number, p_path in number) return number
AS
  l_err         varchar2(2000);
  l_hasUnseen   number  :=0;
  l_uidv        varchar2(100)   := '';
  l_uidbox      varchar2(100);
  l_path        varchar2(1000);
BEGIN
  select path into l_path from er_paths where path_id = p_path;
  
  debugmsg('--------- SelectPathImap("'||l_path||'")');
  send_command(p_conn, CmdCnt||' SELECT "'||l_path||'"');
  if g_reply_status = 'OK' then 
    debugmsg('путь '||p_path||' существует. анализируем стек ответа команды №'||g_CmtCounter);
    
    select uidvalidity into l_uidbox from er_paths where box_box_id = p_box and path_id = p_path;
    l_uidv := FindInAnswer('%UIDVALIDITY%','\[UIDVALIDITY ([0-9]+).*',1,1,'i',1); --FindInAnswer('%UIDVALIDITY%','[0-9]+');
    if l_uidbox is null then 
      debugmsg('фиксируем первое UIDVALIDITY '||l_uidv||' ящика '||p_box||' путь '||p_path);
      update er_paths set uidvalidity = l_uidv where box_box_id = p_box and path_id = p_path;
      commit;
    else
      if l_uidv <> l_uidbox then 
        debugmsg('ВНИМАНИЕ: изменился UIDVALIDITY c '||l_uidbox||' на '||l_uidv);
      end if;
    end if;

    l_hasUnseen := FindInAnswer('%UNSEEN%','\[UNSEEN ([0-9]+).*',1,1,'i',1); --to_number(FindInAnswer('%UNSEEN%','[0-9]+'));
    l_hasUnseen := g_hasUnseen + nvl(l_hasUnseen,0);
--    dbms_output.put_line('UNSEEN='||l_hasUnseen);
    if nvl(l_hasUnseen,0)=0 then 
      update er_boxes set LAST_CHECK_MSG = 'нет новых сообщений' where box_id = p_box;
    else 
      update er_boxes set LAST_CHECK_MSG = 'есть непрочтенные сообщения' where box_id = p_box;
      debugmsg('есть непрочтенные сообщения в ящике '||p_box||' путь '||p_path);
    end if;
    commit;
    return l_hasUnseen;
  else 
    debugmsg('g_reply_status='||g_reply_status);
  end if;

exception 
   when others then
     l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
     debugmsg(l_err);
     return l_hasUnseen;
END;


--==============================================================================
-- по правилам из ER_RULES ищет UID сообщения для загрузки
-- по построенному списку загружает заголовки писем
procedure loadAttachHeaders(p_conn   IN OUT NOCOPY  UTL_TCP.connection, p_mail in number)
is
  l_err             varchar2(2000)  :=  '';
  l_charset         varchar2(100);
  l_encoding        varchar2(100);
  l_filename        varchar2(500);
  l_filesize        number;
  l_header          clob;
  l_attach_count    number := 0;
  l_CONTYPE         varchar2(100);
  l_subj            varchar2(200);
  l_multipart       number;
  l_msg_uid         number;
  l_status          number;
begin
    ----- загружаем залоговки вложений
    l_header := null;
    l_attach_count := null;
    select MSG_UID, substr(SUBJECT,1,200), case when lower(CONTYPE) like 'multipart%' then 1 else 0 end 
      into l_msg_uid, l_subj, l_multipart
    from er_mail where mail_id = p_mail;
    if l_multipart=0 then
      return;
    end if;
    loop
        begin
            l_status := 0;
            send_command(p_conn, CmdCnt||' UID FETCH '||to_char(l_msg_uid)||' body['||to_char(nvl(l_attach_count,0)+2)||'.MIME]', p_debug_supress=>1);
            l_header := FindLastReply;
            EXIT WHEN FindInAnswer('%FETCH%BODY[%.MIME]%','NIL')='NIL';
            l_CONTYPE      := regexp_substr(FindInAnswerToken('CONTENT-TYPE:'),'([^;]*)',1,1,'i',1);
            l_charset      := FindInAnswer('CONTENT-TYPE:%','.*charset="(.*?[^"])',1,1,'i',1);
            l_filename     :=decode_rfc2047(regexp_substr(FindInAnswerToken('CONTENT-TYPE:'),'name\s*=\s*"(.*?)"',1,1,'i',1));
            l_filesize     :=      ExtractN(FindInAnswerToken('Content-Disposition:'),'.*size=([0-9]+[^;])',1,1,'i',1);
            l_encoding     :=               FindInAnswerToken('Content-Transfer-Encoding:');
            l_attach_count := nvl(l_attach_count,0)+1;
        exception
          when others then
            l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
            debugmsg(l_err);
            l_status := -1;
        end;
        insert into er_mail_attach(mail_mail_id, subject, rfc_attach, contype, charset, encoding, filename, ATTACH_SIZE, status)
        values(p_mail, l_subj, l_header, l_CONTYPE, l_charset, l_encoding, l_filename, l_filesize, l_status);
        commit;
    end loop;
    update er_mail set attach_count = l_attach_count where mail_id = p_mail;
    commit;
exception 
   when others then
     l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
     debugmsg(l_err);
end;


--==============================================================================
-- по правилам из ER_RULES ищет UID сообщения для загрузки
function search4Load(p_conn   IN OUT NOCOPY  UTL_TCP.connection, p_box in number, p_path in number) return number
is
  l_err             varchar2(2000)  :=  '';
  l_emailString     varchar2(1000);
  j_str             number;
  has_same_email    number;
begin
  debugmsg('--------- search4Load');
  emailList.delete; 
  emailList.extend;
  -- поиск писем по правилам из ER_RULES
  for i in (select RULE_TEXT, box_box_id, path_path_id from er_rules 
            where 1=1
              and ( (box_box_id = p_box and path_path_id = p_path ) or
                    (box_box_id = p_box and path_path_id is null) or
                    (box_box_id is null)
                  )  
              and enabled=1 
              and sysdate between start_date and end_date
            /*union select 'UNSEEN', p_box, p_path from dual*/)
  loop
      debugmsg('- поиск по команде '||i.RULE_TEXT||' в ящике\пути='||nvl(to_char(i.box_box_id),'<null>')||nvl(to_char(i.path_path_id),'<null>'));
      send_command(p_conn, CmdCnt||' UID SEARCH '||i.RULE_TEXT);
      if g_reply_status = 'OK' then 
        for i in g_lastStackMsg .. g_reply.last
        loop
          l_emailString := FindInAnswer('* SEARCH%','([0-9] ?)+');
          if l_emailString is not null then 
             for j in (SELECT regexp_substr(str, '\S+', 1, level) str 
                        FROM (SELECT l_emailString str FROM dual) t
                        connect by regexp_substr(str,'\S+',1,level) is not null)
             loop
                j_str := to_number(j.str);
                has_same_email := 0;
                for k in emailList.first .. emailList.last
                loop
                  if emailList(k) = j_str then has_same_email :=1; end if;
                end loop;
                if has_same_email=0 then 
                  emailList.extend;
                  emailList(emailList.last) := j_str;
                end if;
             end loop; -- закончили пополнять коллекцию
          end if; -- закончили разбирать ответ сервера на команду SEАRCH
        end loop; -- по всем строкам ответа от сервера
      end if; -- завершили обработку "ОК" от всех команды SERCH
  end loop;
  emailList.delete(1);
  debugmsg('Найдено '||emailList.Count||' писем для загрузки');

  return emailList.count;
  
exception 
   when others then
     l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
     debugmsg(l_err);
end;

--==============================================================================
-- по построенному списку emailList загружает заголовки писем
procedure loadHeaders(p_conn   IN OUT NOCOPY  UTL_TCP.connection, p_box in number, p_path in number)
is
  l_err             varchar2(2000)  :=  '';
  l_res             number;
  
  l_mail_id         number;
  l_size            number;
  l_date_tz         timestamp with time zone;
  l_FROM            varchar2(200);
  l_SUBJECT         varchar2(500);
  l_CONTYPE         varchar2(100);
  l_MESSAGE_ID      varchar2(1000);
  l_inreplyto       varchar2(100);
  l_boundary        varchar2(100);
  l_retpath         varchar2(100);

  l_header          clob;
begin
  debugmsg('--------- loadHeaders');
  -- непосредственно загрузка заголовков писем с установкой флага прочтения
  if search4Load(p_conn, p_box, p_path) >0 then 
    --debugmsg('Найдено '||emailList.Count||' писем для загрузки');
    for i in emailList.first .. emailList.last
    loop
      select count(1) into l_res from er_mail where box_box_id = p_box and path_path_id = p_path and msg_uid = emailList(i);
      if l_res = 0 then 
        --debugmsg('--==== load message uid '||emailList(i));
        send_command(p_conn, CmdCnt||' UID FETCH '||emailList(i)||' (BODY[HEADER] RFC822.SIZE)', p_debug_supress=>1);
        l_header := FindLastReply;
        
        if g_reply_status = 'OK' then 
          begin
            ----- загружаем залоговки писем
            l_size        := FindInAnswerN('%RFC822.SIZE%','RFC822.SIZE ([0-9]+)',1,1,'i',1);      
            l_date_tz     := FindInAnswerD('DATE:%','\d.*', 'dd Mon YYYY hh24:mi:ss +TZHTZM','NLS_LANGUAGE=AMERICAN'); --trim(FindInAnswer('DATE:%','\d.*'));
            l_FROM        := decode_rfc2047(FindInAnswerToken('FROM:'));
            l_SUBJECT     := decode_rfc2047(FindInAnswerToken('SUBJECT:'));
            l_CONTYPE     := FindInAnswer('CONTENT-TYPE:%',' (.)+/(.)+[;]');
            l_MESSAGE_ID  := FindInAnswerToken('MESSAGE-ID:');
            l_inreplyto   := FindInAnswerToken('In-Reply-To:'/*,' .*[^;]')||')'*/);
            l_boundary    := substr(FindInAnswer('%boundary=%','".+[^";]'),2);
            l_retpath     := coalesce(FindInAnswer('Reply-To:%','<.*>'),FindInAnswer('Return-path:%','<.*>'),regexp_substr(l_from,'<.*>'));
       
            send_command(p_conn, CmdCnt||' UID FETCH '||emailList(i)||' BODY[1]', p_debug_supress=>0, p_use_gclob=>1);
            dbms_output.put_line('glob='||length(g_clob));
            dbms_output.put_line('glob='||substr(g_clob,1,100));
            
            insert into er_mail(msg_uid,box_box_id,path_path_id, msg_size, rfc_date  ,
                        rfc_from  ,subject   ,contype   ,message_id, in_reply_to, boundary,
                        return_path,rfc_header, msg_text)
            values(emailList(i), p_box,p_path, l_size, l_date_tz, 
                     l_from, l_subject, l_CONTYPE,l_MESSAGE_ID, l_inreplyto, l_boundary,
                     l_retpath, l_header, g_clob)
            returning mail_id into l_mail_id;
            commit; -- после того как зачитаем письмо полностью.
          
            loadAttachHeaders(p_conn, l_mail_id);
         
          exception
            when others then
              l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
              debugmsg(l_err);
              insert into er_mail(msg_uid,box_box_id,path_path_id, rfc_header)
                     values(emailList(i), p_box,     p_path,       l_header);
              commit; -- после того как зачитаем письмо полностью.
          end;
          -- ставим статус "Прочитано"
          --send_command(p_conn, CmdCnt||' UID STORE '||emailList(i)||' +FLAGS.SILENT \Seen', p_debug_supress=>1);
        else
          debugmsg('Статус UID сообщения '||emailList(i)||' равен '||g_reply_status||'. Пропускаем');
          insert into er_mail(msg_uid,box_box_id,path_path_id, rfc_header, status)
                 values(emailList(i), p_box,     p_path,       l_header,-1);
          commit;
        end if;
      else
        debugmsg('а есть уже письмо с UID='||emailList(i));
      end if;
    end loop;
  end if;

exception 
   when others then
     l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
     debugmsg(l_err);
end;

--==============================================================================
function g_checkBox(p_box   number default null)return number
is
  l_conn    UTL_TCP.connection;
  l_err     varchar2(3000);
  l_protocol varchar2(100);
  l_hostname varchar2(100);
  l_username varchar2(100);
  l_pass     varchar2(100);  
begin
  debugmsg('Проверяю ящик №'||p_box/*||' '||i.username||' на '||i.hostname*/);
  select protocol, hostname, username, pass into l_protocol, l_hostname, l_username, l_pass
  from er_boxes where box_id = box_id;
  if l_protocol='imap' then 
    l_conn := emailreader.loginImap(l_hostname, l_username, l_pass);
    if l_conn.remote_port is null then 
      dbms_output.put_line('сервера не существует'); 
      return res_error;
    end if;
    update er_boxes set LAST_CHECK = sysdate where box_id = p_box;
    commit;
    for j in (select * from er_paths where box_box_id = p_box and enabled=1 order by isdefault desc)
    loop
      if selectPathImap(l_conn, p_box, j.path_id)>0 then 
        loadHeaders(l_conn, p_box, j.path_id);
      end if;
    end loop;
    emailreader.logoutImap(l_conn);
  end if; --i.protocol='imap' 
  return res_success;
exception 
  when others then
    l_err := dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace();
    debugmsg(l_err);
    return res_error;
end;

-------------------------------------------------------------------------
begin
  g_lastStackMsg :=0;
  dbms_lob.createtemporary(g_clob, false);
end;
/


-- End of DDL Script for Package Body DEPSTAT.EMAILREADER

