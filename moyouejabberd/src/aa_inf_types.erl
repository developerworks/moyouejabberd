%%
%% Autogenerated by Thrift Compiler (1.0.0-dev)
%%
%% DO NOT EDIT UNLESS YOU ARE SURE THAT YOU KNOW WHAT YOU ARE DOING
%%

-module(aa_inf_types).

-include("aa_inf_types.hrl").

-export([struct_info/1, struct_info_ext/1]).

struct_info('aaRequest') ->
  {struct, [{1, string},
          {2, string},
          {3, string}]}
;

struct_info('i am a dummy struct') -> undefined.

struct_info_ext('aaRequest') ->
  {struct, [{1, required, string, 'sn', undefined},
          {2, required, string, 'content', undefined},
          {3, optional, string, 'type', "xml"}]}
;

struct_info_ext('i am a dummy struct') -> undefined.

