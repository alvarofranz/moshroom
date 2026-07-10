////////////////////////////////////////////////////////////////////////////////
//
// M O S H R O O M
//
// Copyright (C) 2026 Moshroom
//
// This file is part of Moshroom.
//
// Moshroom is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Moshroom is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Moshroom. If not, see <http://www.gnu.org/licenses/>.
//
////////////////////////////////////////////////////////////////////////////////

#import <Foundation/Foundation.h>


enum MoshMoshPrediction {
  MoshMoshPredictionAdaptive,
  MoshMoshPredictionAlways,
  MoshMoshPredictionNever,
  MoshMoshPredictionExperimental
};

enum MoshMoshExperimentalIP {
  MoshMoshExperimentalIPNone,
  MoshMoshExperimentalIPLocal,
  MoshMoshExperimentalIPRemote,
};

enum MoshAgentForward {
  MoshAgentForwardNo,
  MoshAgentForwardConfirm,
  MoshAgentForwardYes,
};


@interface MoshHosts : NSObject <NSSecureCoding>

@property (nonatomic, strong) NSString *host;
@property (nonatomic, strong) NSString *hostName;
@property (nonatomic, strong) NSNumber *port;
@property (nonatomic, strong) NSString *user;
@property (nonatomic, strong) NSString *passwordRef;
@property (readonly) NSString *password;
@property (nonatomic, strong) NSString *key;
@property (nonatomic, strong) NSString *moshServer;
@property (nonatomic, strong) NSString *moshPredictOverwrite;
@property (nonatomic, strong) NSNumber *moshExperimentalIP;
@property (nonatomic, strong) NSNumber *moshPort;
@property (nonatomic, strong) NSNumber *moshPortEnd;
@property (nonatomic, strong) NSString *moshStartup;
// A command typed into the interactive session right after connecting (ssh AND mosh) — e.g.
// "cd dev && claude". Independent of moshStartup (screen -r / tmux attach); it runs *inside* whatever
// session comes up.
@property (nonatomic, strong) NSString *commandOnConnect;
// Optional free-text one-liner shown in gray next to the alias (e.g. "a demo host for apple reviews").
@property (nonatomic, strong) NSString *hostDescription;
@property (nonatomic, strong) NSNumber *prediction;
@property (nonatomic, strong) NSString *proxyCmd;
@property (nonatomic, strong) NSString *proxyJump;
@property (nonatomic, strong) NSString *sshConfigAttachment;
@property (nonatomic, strong) NSNumber *agentForwardPrompt;
@property (nonatomic, strong) NSArray<NSString *> *agentForwardKeys;
// When this entry was last edited on any device — powers the iCloud conflict merge
// (per-host newest-wins). Nil on entries saved before this field existed (treated as oldest).
@property (nonatomic, strong) NSDate *lastModified;

+ (instancetype)withHost:(NSString *)ID;
+ (void)loadHosts NS_SWIFT_NAME(loadHosts());
+ (BOOL)saveHosts;
+ (BOOL)forceSaveHosts;
+ (instancetype)saveHost:(NSString *)host
             withNewHost:(NSString *)newHost
                hostName:(NSString *)hostName
                 sshPort:(NSString *)sshPort
                    user:(NSString *)user
                password:(NSString *)password
                 hostKey:(NSString *)hostKey
              moshServer:(NSString *)moshServer
    moshPredictOverwrite:(NSString *)moshPredictOverwrite
      moshExperimentalIP:(enum MoshMoshExperimentalIP)moshExperimentalIP
           moshPortRange:(NSString *)moshPortRange
              startUpCmd:(NSString *)startUpCmd
         commandOnConnect:(NSString *)commandOnConnect
         hostDescription:(NSString *)hostDescription
              prediction:(enum MoshMoshPrediction)prediction
                proxyCmd:(NSString *)proxyCmd
               proxyJump:(NSString *)proxyJump
     sshConfigAttachment:(NSString *)sshConfigAttachment
      agentForwardPrompt:(enum MoshAgentForward)agentForwardPrompt
        agentForwardKeys:(NSArray<NSString *> *)agentForwardKeys
;
+ (void)_replaceHost:(MoshHosts *)newHost;
+ (NSMutableArray<MoshHosts *> *)all;
+ (NSArray<MoshHosts *> *)allHosts;
+ (NSInteger)count;


- (id)initWithAlias:(NSString *)alias
           hostName:(NSString *)hostName
            sshPort:(NSString *)sshPort
               user:(NSString *)user
        passwordRef:(NSString *)passwordRef
            hostKey:(NSString *)hostKey
         moshServer:(NSString *)moshServer
      moshPortRange:(NSString *)moshPortRange
moshPredictOverwrite:(NSString *)moshPredictOverwrite
 moshExperimentalIP:(enum MoshMoshExperimentalIP)moshExperimentalIP
         startUpCmd:(NSString *)startUpCmd
         prediction:(enum MoshMoshPrediction)prediction
           proxyCmd:(NSString *)proxyCmd
          proxyJump:(NSString *)proxyJump
sshConfigAttachment:(NSString *)sshConfigAttachment
 agentForwardPrompt:(enum MoshAgentForward)agentForwardPrompt
   agentForwardKeys:(NSArray<NSString *> *)agentForwardKeys;

@end
