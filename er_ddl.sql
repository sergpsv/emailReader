/*begin execute immediate 'drop sequence er_seq'; exception when others then null; end;
begin execute immediate 'drop table er_boxes'; exception when others then null; end;
begin execute immediate 'drop table er_paths'; exception when others then null; end;
*/

CREATE SEQUENCE er_seq
  INCREMENT BY 1
  START WITH 1
  MINVALUE 1
  MAXVALUE 999999999999999999999999999
  NOCYCLE
  NOORDER
  CACHE 2
/

--------------------------------------------------------------------------------
begin execute immediate 'drop table er_boxes'; exception when others then null; end;
/
create table er_boxes
(
  box_id        number,
  username      varchar2(100),
  hostname      varchar2(100),
  pass          varchar2(100),
  passmd5       varchar2(100),
  protocol      varchar2(50) default 'imap',
  last_check    date,
  last_check_msg    varchar2(203),
  enabled       number
 ,CONSTRAINT ER_BOXES_CHECK_PROT  CHECK (protocol in ('imap','pop3'))
 ,constraint ER_BOXES_PK primary key (box_id)
)
pctfree 0 
/
comment on table er_boxes is 'Почтовые ящики из которых необходимо чтение почты'
/
CREATE or replace TRIGGER ER_BOXES_TRG
 BEFORE INSERT ON ER_BOXES
 FOR EACH ROW 
Declare
  l_cnt number;
begin
  select count(1) into l_cnt from er_boxes where upper(username) = upper(:new.username);
  if l_cnt >0 then 
    RAISE_APPLICATION_ERROR(-20000,'Такое имя ящика уже существует');
  end if;

  :new.passmd5 := dbms_obfuscation_toolkit.md5(input=>utl_raw.cast_to_raw(:new.pass));
  :new.pass := null;
  
  select er_seq.nextval into :new.box_id from dual;
  
end;
/
CREATE or replace TRIGGER ER_BOXES_TRG_upd
 before update ON ER_BOXES
 FOR EACH ROW 
Declare
  l_cnt number;
begin
  :new.passmd5 := dbms_obfuscation_toolkit.md5(input=>utl_raw.cast_to_raw(:new.pass));
--  :new.pass := null;
end;
/

--------------------------------------------------------------------------------
begin execute immediate 'drop table er_paths'; exception when others then null; end;
/
create table er_paths
(
  path_id       number,
  box_box_id    number,
  path          varchar2(200)   default 'INBOX/EMAILREADER',
  path_del      varchar2(3)     default '/',
  isDefault     number          default 1   not null,
  enabled       number          default 0   not null,
  uidvalidity   varchar2(50)
  ,constraint er_paths_PK     primary key (path_id)
  ,constraint er_paths_FK_box foreign key (box_box_id) references er_boxes(box_id)
)
pctfree 0 
/
comment on table er_paths is 'Пути к папке с письмами для почтового робота'
/


CREATE or replace TRIGGER er_paths_trg BEFORE INSERT ON er_paths FOR EACH ROW 
declare
  l_cnt number;  
begin
  select count(1) into l_cnt from er_paths where box_box_id = :new.box_box_id and upper(path)=upper(trim(:new.path));
  if l_cnt>0 then 
    raise_application_error(-20000,'Такой путь в этом ящике уже существует');
  end if;
  :new.path := trim(:new.path);

  select count(1) into l_cnt from er_paths where box_box_id = :new.box_box_id and isdefault=1;
  if l_cnt>0 and :new.isDefault=1 then 
    raise_application_error(-20000,'невозможно добавить еще один путь по умолчанию для этого ящика');
  end if;
  
  select er_seq.nextval into :new.path_id from dual;
end;
/
--drop trigger er_paths_trg_upd;
/*CREATE or replace TRIGGER er_paths_trg_upd BEFORE update ON er_paths FOR EACH ROW 
declare
  l_cnt number;  
begin
  select count(1) into l_cnt from er_paths where box_box_id = :new.box_box_id and upper(path)=upper(trim(:new.path));
  if l_cnt>0 then 
    raise_application_error(-20000,'Такой путь в этом ящике уже существует');
  end if;

  select count(1) into l_cnt from er_paths where box_box_id = :new.box_box_id and isdefault=1;
  if l_cnt>0 and :new.isDefault=1 then 
    raise_application_error(-20000,'невозможно обновить еще один путь как путь по умолчанию для этого ящика. Сначала отмените старый путь');
  end if;
  
end;
/
*/

--------------------------------------------------------------------------------
begin execute immediate 'drop table er_rules'; exception when others then null; end;
/
create table er_rules
(
  rule_id       number,
  box_box_id    number,
  path_path_id  number,
  rule_text     varchar2(1000),
  enabled       number default 0 not null,
  start_date    date default sysdate,
  end_date      date default to_date('31.12.2999','dd.mm.yyyy')
  ,constraint er_rules_FK_box   foreign key (box_box_id)   references er_boxes(box_id)
  ,constraint er_rules_FK_path  foreign key (path_path_id) references er_paths(path_id)
)
pctfree 0
/
comment on table er_rules is 'Правила выборки писем из ящика';
comment on column er_rules.box_box_id is 'если задан, то правило применяется только к указанному ящику. Иначе - ко всем ящикам';
comment on column er_rules.path_path_id is 'если задан, то правило применяется только к указанному пути. Иначе - ко всем путям в данном ящике.';

CREATE or replace TRIGGER er_rules_trg BEFORE INSERT ON er_rules FOR EACH ROW 
begin
  select er_seq.nextval into :new.rule_id from dual;
end;
/
-- select * from er_rules;
--------------------------------------------------------------------------------
/*begin execute immediate 'drop table er_rule_parts'; exception when others then null; end;
/
create table er_rule_parts
(
  part_id       number,
  rule_rule_id  number
  ,constraint er_rule_parts_PK        primary key (part_id)
  ,constraint er_rule_parts_FK_rules  foreign key (rule_rule_id)   references er_rules(rule_id)
)
pctfree 0
/
comment on table er_rules is 'компоненты правил по RFC2060 (команда search) http://rfc2.ru/2060.rfc'
/
CREATE or replace TRIGGER er_rules_trg BEFORE INSERT ON er_rules FOR EACH ROW 
begin
  select er_seq.nextval into :new.rule_id from dual;
end;
/
*/

--------------------------------------------------------------------------------
begin execute immediate 'drop table er_mail'; exception when others then null; end;
/
create table er_mail
(
  mail_id       number,
  parent_mail_id number,
  msg_uid       number,
  box_box_id    number,
  path_path_id  number,
  msg_size      number,
  rfc_date      timestamp with time zone,
  rfc_from      varchar2(200),
  subject       varchar2(1000),
  contype       varchar2(100),
  message_id    varchar2(150),
  In_Reply_To   varchar2(150),
  boundary      varchar2(150),
  return_path   varchar2(150),
  rfc_header    clob,
  msg_contype   varchar2(100),
  msg_charset   varchar2(100),
  msg_encode    varchar2(100),
  msg_rfc       clob,
  msg_text      clob,
  attach_count  number,
  status        number default 0, -- 0-загружен только заголовок, 1-загружено полностью, 2-удалено
  action        number default 0, -- 
  navi_date     date default sysdate
  ,constraint er_mail_PK      primary key (mail_id)
  ,constraint er_mail_FK_box  foreign key (box_box_id)   references er_boxes(box_id)
  ,constraint er_mail_FK_path foreign key (path_path_id) references er_paths(path_id)
)
pctfree 0 
/
comment on table er_mail is 'Содержимое ящика - письма с заголовком без вложений';
comment on column er_mail.mail_id       is 'Идентификатор письма в базе';
comment on column er_mail.parent_mail_id       is 'Идентификатор родительского письма в базе (по message_id)';
comment on column er_mail.msg_uid       is 'Уникальный идентификатор письма на сервере';
comment on column er_mail.box_box_id    is 'ссылка на ящик er_boxes';
comment on column er_mail.rfc_date      is 'из заголовка письма DATE:';
comment on column er_mail.rfc_from      is 'из заголовка письма FROM:';
comment on column er_mail.subject       is 'из заголовка письма SUBSJECT:';
comment on column er_mail.contype       is 'из заголовка письма Content-Type:';
comment on column er_mail.message_id    is 'из заголовка письма Message-ID: для отслеживания цепочек писем - исходящее сообщение';
comment on column er_mail.In_Reply_To   is 'из заголовка письма In_Reply_To: для отслеживания цепочек писем - в ответ на какое сообщение получено';
comment on column er_mail.boundary      is 'разделитель из заголовка для мульпарт сообщений';
comment on column er_mail.return_path   is 'Чистый емал адрес для ответа из заголовка письма return-path: Если пусто в заголовке, то из FROM:';
comment on column er_mail.rfc_header    is 'Полный заголовок - в случае проблем с получением какого-либо поля';
comment on column er_mail.msg_text      is 'Тело сообщения';
comment on column er_mail.attach_count  is 'кол-во вложений';
comment on column er_mail.status        is '0-загружен только заголовок, 1-загружено полностью, 2-удалено';
comment on column er_mail.action        is 'действие над письмом';
comment on column er_mail.navi_date     is 'дата внесения записи в базу';

CREATE or replace TRIGGER ER_mail_TRG
 BEFORE INSERT ON ER_mail
 FOR EACH ROW 
Declare
  l_cnt number;
begin
  select er_seq.nextval into :new.mail_id from dual;
end;
/


--------------------------------------------------------------------------------
begin execute immediate 'drop table er_mail_attach'; exception when others then null; end;
/
create table er_mail_attach
(
   attc_id      number,
   mail_mail_id number,
   subject      varchar2(200), 
   rfc_attach   clob,
   attach_size  number,
   contype      varchar2(100),
   charset      varchar2(50),
   encoding     varchar2(50),
   filename     varchar2(100),
   status       number  default 0
  ,constraint er_mail_attach_PK      primary key (attc_id)
  ,constraint er_mail_attach_FK_box  foreign key (mail_mail_id)  references er_mail(mail_id)
)
pctfree 0 
/
comment on table er_mail_attach is 'Вложения из писем';
comment on column er_mail_attach.attc_id      is 'ID вложения';
comment on column er_mail_attach.mail_mail_id is 'ссылка на er_mail';
comment on column er_mail_attach.rfc_attach   is 'MIME заголовок';
comment on column er_mail_attach.attach_size  is 'размер вложения';
comment on column er_mail_attach.contype      is 'Content-type';
comment on column er_mail_attach.charset      is 'charset';
comment on column er_mail_attach.encoding     is 'encoding';
comment on column er_mail_attach.filename     is 'имя вложения';

CREATE or replace TRIGGER er_attach_TRG
 BEFORE INSERT ON er_mail_attach
 FOR EACH ROW 
Declare
  l_cnt number;
begin
  select er_seq.nextval into :new.attc_id from dual;
end;
/




--===============
delete from er_paths;
delete from er_boxes;
--select * from er_boxes;
insert into er_boxes values(1,'sergey.parshukov','rst-mail.megafon.ru','Rhfcyjlfh12', null/*passmd5*/, 'imap', null/*last_check*/, null/*last_check_msg*/, 1 /*enabled*/);
insert into er_paths values(1,1,'INBOX/&BB8EPgRHBEIEPgQyBEsENQ- &BEAEPgQxBD4EQgRL-/EmailReader','/',1,1,null);
insert into er_paths values(2,1,'INBOX/&BB8EPgRHBEIEPgQyBEsENQ- &BEAEPgQxBD4EQgRL-/EmailReader/testing','/',0,1,null);
insert into er_rules values(1,null,null,'UNSEEN',1,sysdate,to_date('31.12.2999'));
insert into er_rules values(2,1,3,'ALL',1,sysdate,to_date('31.12.2999'));

commit;
select * from er_boxes;
select * from er_paths;
select * from er_rules;

--update er_boxes set pass = 'xxx' where USERNAME = 'sparshukov';
--update er_boxes set pass = 'czoa4zws' where USERNAME = 'sparshukov';

--===================================
delete from tlog where dinsdate>trunc(sysdate) and sid=sys_context('userEnv','sid') and PART='emailreader';
commit;
--truncate table er_mail;
delete from er_mail_attach;
delete from er_mail;
begin
  dbms_output.put_line(EMAILREADER.g_checkBox(1));
end;
/
--select * from er_boxes;
--select * from er_paths;
select * from v_tlog where sid=sys_context('userEnv','sid') order by iid;
select * from er_mail order by RFC_DATE desc;
select * from er_mail_attach order by mail_mail_id desc, attc_id;



